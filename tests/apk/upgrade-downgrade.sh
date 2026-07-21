#!/bin/sh
# tests/apk/upgrade-downgrade.sh
#
# Slice D3 test (RFC docs/rfc-apk-builds.md ss4.1/4.7, ss6 slice D3) -- the
# LAST /tdd slice of the apk-builds RFC. Two independent parts, both against
# the pinned OpenWrt 25.12 aarch64 rootfs container (RFC ss5's hermetic-C2
# style scoping: aarch64 is enough to prove the MECHANISM, cross-arch
# packaging is already proven by A5b/C1b):
#
#   Part A -- ipk -> apk coexistence (24.10 -> 25.12 sysupgrade). apk and
#     opkg are DISJOINT package databases (ss4.1) -- `apk add` cannot see an
#     opkg-tracked "tailscale" at all. This part SIMULATES a stale ipk
#     install's on-disk footprint surviving a sysupgrade into an apk-only
#     25.12 rootfs (confirmed empirically this slice: the pinned aarch64
#     rootfs ships NO opkg binary at all -- so the realistic scenario is
#     leftover /usr/lib/opkg/info/tailscale.* + payload + UCI state from a
#     PREVIOUS ipk install, not a live opkg binary) -- real payload files at
#     their real paths (extracted from the actual `--target ipk` build),
#     the real postinst run live to create real network/firewall UCI state,
#     PLUS a simulated killswitch-enabled DNS redirect (the RFC's own
#     concrete example of "orphaned firewall rules from an ipk postrm that
#     never ran" -- see tailscale.postrm's DNS_BACKUP handling) so there is
#     genuine orphan-able state to assert against, not just inert files.
#     Then runs install.sh's own apk_path() (real dispatch, real signed
#     feed, mirroring tests/apk/install-dispatch.sh's Part 4 pattern) and
#     asserts NO residual/duplicate state: no leftover opkg tracking files,
#     no leftover opkg status stanza, the orphaned DNS killswitch state is
#     cleaned up (not left dangling), and a single, apk-owned tailscale is
#     left running the real newly-installed binary.
#
#   Part B -- tested downgrade (documented in docs/INSTALL.md's
#     "Downgrading (apk)" section). Installs a NEWER local .apk (offline,
#     the established A4/A5b stub-dep-repo mechanism), then runs the EXACT
#     documented command (`apk add --allow-untrusted ./<old>.apk`) against
#     an OLDER local .apk and asserts it succeeds, verified by
#     `tailscaled --version` actually reporting the older version
#     afterwards -- not just an exit-code check. Empirically confirmed
#     this slice (see handoff): apk-tools 3.0.2 supports a plain local-file
#     downgrade with no extra force flags beyond --allow-untrusted (apk's
#     own transaction log even says "Downgrading tailscale (new -> old)");
#     docs/INSTALL.md's documented command needed NO changes.
#
# Uses the shared tests/apk/lib.sh harness + the A4/A5b/C2/D1 binfmt/
# exec-retry machinery and stub-dep-repo trick. Never commits/pushes
# anything; ephemeral signing key lives only in a mktemp scratch dir.
#
# Usage:
#   sh tests/apk/upgrade-downgrade.sh              # both parts
#   sh tests/apk/upgrade-downgrade.sh --coexist-only
#   sh tests/apk/upgrade-downgrade.sh --downgrade-only
#
# Env overrides:
#   UPGRADE_TEST_VERSION / UPGRADE_TEST_PKG_RELEASE -- the "current" version
#     built for Part A and the "new" version installed in Part B (default
#     1.92.2-r1, matching this repo's other tests/apk/*.sh).
#   DOWNGRADE_OLD_VERSION -- the older, real tailscale release built fresh
#     for Part B's downgrade target (default 1.88.0 -- a real, published
#     tailscale release older than UPGRADE_TEST_VERSION, per the RFC's own
#     "a real version delta is preferred" guidance).

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
INSTALL_DIR="${REPO_ROOT}/scripts"
PKG_DIR="${REPO_ROOT}/tailscale-package"
ARCHES_JSON="${REPO_ROOT}/arches.json"
ADB_SIGN_PY="${REPO_ROOT}/scripts/adb-sign.py"
CACHE_DIR="${ROOTFS_CACHE_DIR:-${SCRIPT_DIR}/.cache}"
ARCH="aarch64_cortex-a53"

# shellcheck source=tests/apk/lib.sh
. "${SCRIPT_DIR}/lib.sh"

require_cmd jq
require_cmd docker
require_cmd openssl
require_cmd curl
require_cmd python3

RUN_COEXIST=1
RUN_DOWNGRADE=1
case "${1:-}" in
    --coexist-only) RUN_DOWNGRADE=0 ;;
    --downgrade-only) RUN_COEXIST=0 ;;
esac

if [ ! -f "${PKG_DIR}/Dockerfile" ]; then
    echo "FAIL: ${PKG_DIR}/Dockerfile not found" >&2
    exit 1
fi
if [ ! -f "${INSTALL_DIR}/install.sh" ] || [ ! -f "${INSTALL_DIR}/lib-install.sh" ]; then
    echo "FAIL: scripts/install.sh or scripts/lib-install.sh not found" >&2
    exit 1
fi

TEST_VERSION="${UPGRADE_TEST_VERSION:-1.92.2}"
TEST_PKG_RELEASE="${UPGRADE_TEST_PKG_RELEASE:-1}"
EXPECT_VERSION="${TEST_VERSION}-r${TEST_PKG_RELEASE}"
OLD_VERSION="${DOWNGRADE_OLD_VERSION:-1.88.0}"
OLD_PKG_RELEASE="1"
EXPECT_OLD_VERSION="${OLD_VERSION}-r${OLD_PKG_RELEASE}"

mkdir -p "${CACHE_DIR}"

WORKDIR=$(mktemp -d)
CLEANUP_CIDS=""
SRV_PIDS=""
cleanup() {
    for c in ${CLEANUP_CIDS}; do
        docker rm -f "${c}" >/dev/null 2>&1 || true
    done
    for p in ${SRV_PIDS}; do
        kill "${p}" >/dev/null 2>&1 || true
    done
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT
track() { CLEANUP_CIDS="${CLEANUP_CIDS} $1"; }
untrack_and_remove() {
    docker rm -f "$1" >/dev/null 2>&1 || true
    CLEANUP_CIDS=$(echo "${CLEANUP_CIDS}" | sed "s/$1//")
}

BINFMT_DONE=0
ensure_binfmt() {
    if [ "${BINFMT_DONE}" -eq 1 ]; then return 0; fi
    BINFMT_DONE=1
    echo "Registering qemu-user binfmt emulators..." >&2
    register_standard_qemu_binfmt || echo "WARN: standard binfmt registration failed (continuing)" >&2
    register_openwrt_mips_binfmt || echo "WARN: OpenWrt mips binfmt registration failed (continuing)" >&2
}
exec_in_container() {
    _cid="$1"; shift
    _out=$(docker exec "${_cid}" "$@" 2>&1) && { printf '%s' "${_out}"; return 0; }
    case "${_out}" in
        *"exec format error"*)
            ensure_binfmt
            _out=$(docker exec "${_cid}" "$@" 2>&1) && { printf '%s' "${_out}"; return 0; }
            ;;
    esac
    printf '%s' "${_out}"
    return 1
}

# --- pinned rootfs: download (cached) + sha256-verify + docker import -----
URL=$(jq -r --arg n "${ARCH}" '.[] | select(.name==$n) | .rootfs_url' "${ARCHES_JSON}")
PIN=$(jq -r --arg n "${ARCH}" '.[] | select(.name==$n) | .rootfs_sha256' "${ARCHES_JSON}")
ROOTFS_IMAGE_TAG="owrt2512-rootfs:${ARCH}"
DEST="${CACHE_DIR}/$(basename "${URL}")"
if [ ! -f "${DEST}" ] || [ "$(sha256sum "${DEST}" | awk '{print $1}')" != "${PIN}" ]; then
    echo "Downloading ${URL}"
    curl -fsSL -o "${DEST}.part" "${URL}"
    mv "${DEST}.part" "${DEST}"
fi
ACTUAL=$(sha256sum "${DEST}" | awk '{print $1}')
if [ "${ACTUAL}" != "${PIN}" ]; then
    log_fail "rootfs sha256 mismatch for ${DEST} (expected ${PIN}, got ${ACTUAL})"
    harness_finish "tests/apk/upgrade-downgrade.sh"
fi
docker import "${DEST}" "${ROOTFS_IMAGE_TAG}" >/dev/null
echo "OK: rootfs sha256 verified + imported ${ROOTFS_IMAGE_TAG}"

# --- stub-dep repo builder (A4/A5b/C2/D1 trick, reused verbatim) ---------
# Built once against the current-version build image and reused by both
# parts (kmod-tun/ip-full/conntrack -- not resolvable offline; ca-bundle is
# already in the base image).
build_stub_repo() {
    _build_image="$1"
    _out_dir="$2"
    _sid=$(docker create "${_build_image}" sh -c "sleep 600")
    track "${_sid}"
    docker start "${_sid}" >/dev/null
    docker exec "${_sid}" mkdir -p /stubwork/empty /stubout
    for dep in kmod-tun ip-full conntrack; do
        docker exec "${_sid}" sh -c \
            "apk mkpkg --allow-untrusted --info 'name:${dep}' --info 'version:1-r1' --info 'arch:${ARCH}' --files /stubwork/empty --output /stubout/${dep}-1-r1.apk"
    done
    docker exec "${_sid}" sh -c "apk mkndx --allow-untrusted --output /stubout/packages.adb /stubout/*.apk"
    mkdir -p "${_out_dir}"
    docker cp "${_sid}:/stubout/." "${_out_dir}/"
    untrack_and_remove "${_sid}"
}

echo ""
echo "############################################"
echo "### Building current-version (${EXPECT_VERSION}) apk + ipk stages"
echo "############################################"

BUILD_IMAGE_TAG="tailscale-apk-upgradedowngrade-build:${ARCH}"
docker build \
    --target apk \
    --build-arg TAILSCALE_VERSION="${TEST_VERSION}" \
    --build-arg PKG_RELEASE="${TEST_PKG_RELEASE}" \
    --build-arg OPENWRT_ARCH="${ARCH}" \
    --build-arg SKIP_UPX=1 \
    -t "${BUILD_IMAGE_TAG}" -f "${PKG_DIR}/Dockerfile" "${PKG_DIR}"

IPK_IMAGE_TAG="tailscale-ipk-upgradedowngrade-build:${ARCH}"
docker build \
    --target ipk \
    --build-arg TAILSCALE_VERSION="${TEST_VERSION}" \
    --build-arg PKG_RELEASE="${TEST_PKG_RELEASE}" \
    --build-arg OPENWRT_ARCH="${ARCH}" \
    --build-arg SKIP_UPX=1 \
    -t "${IPK_IMAGE_TAG}" -f "${PKG_DIR}/Dockerfile" "${PKG_DIR}"

mkdir -p "${WORKDIR}/repo"
NCID=$(docker create "${BUILD_IMAGE_TAG}")
track "${NCID}"
docker cp "${NCID}:/out/${ARCH}/tailscale-${EXPECT_VERSION}.apk" "${WORKDIR}/repo/"
untrack_and_remove "${NCID}"
if [ ! -s "${WORKDIR}/repo/tailscale-${EXPECT_VERSION}.apk" ]; then
    log_fail "current-version .apk missing/empty after extraction"
    harness_finish "tests/apk/upgrade-downgrade.sh"
fi
echo "OK: built tailscale-${EXPECT_VERSION}.apk"

ICID=$(docker create "${IPK_IMAGE_TAG}")
track "${ICID}"
docker cp "${ICID}:/tailscale_${TEST_VERSION}_${ARCH}.ipk" "${WORKDIR}/tailscale.ipk"
untrack_and_remove "${ICID}"
if [ ! -s "${WORKDIR}/tailscale.ipk" ]; then
    log_fail ".ipk missing/empty after extraction"
    harness_finish "tests/apk/upgrade-downgrade.sh"
fi
echo "OK: built tailscale_${TEST_VERSION}_${ARCH}.ipk"

build_stub_repo "${BUILD_IMAGE_TAG}" "${WORKDIR}/stubrepo"
echo "OK: local stub-dep repo built (kmod-tun, ip-full, conntrack)"

# =====================================================================
# Part A -- ipk -> apk coexistence
# =====================================================================
if [ "${RUN_COEXIST}" -eq 1 ]; then
echo ""
echo "############################################"
echo "### Part A: ipk -> apk coexistence (filesystem-level detection)"
echo "############################################"

# --- extract the real .ipk's control.tar.gz/data.tar.gz on the HOST -----
# ("OpenWrt .ipk = gzipped tar, not ar" -- C1a finding, reused here).
mkdir -p "${WORKDIR}/ipk-extract"
( cd "${WORKDIR}/ipk-extract" && tar -xzf "${WORKDIR}/tailscale.ipk" )
mkdir -p "${WORKDIR}/ipk-extract/control" "${WORKDIR}/ipk-extract/data"
( cd "${WORKDIR}/ipk-extract/control" && tar -xzf "../control.tar.gz" )
( cd "${WORKDIR}/ipk-extract/data" && tar -xzf "../data.tar.gz" )

# The real on-device file list this ipk installed (used both to lay the
# payload down AND to build opkg's own tailscale.list -- absolute paths,
# leading "./" stripped to "/", directory entries excluded).
( cd "${WORKDIR}/ipk-extract/data" && find . -type f | sed 's#^\.#/#' ) > "${WORKDIR}/ipk-extract/tailscale.list"

CID=$(docker create --network host "${ROOTFS_IMAGE_TAG}" sh -c "sleep 900")
track "${CID}"
docker start "${CID}" >/dev/null
if ! exec_in_container "${CID}" apk --print-arch >/dev/null; then
    log_fail "Part A: apk --print-arch failed in target container"
    untrack_and_remove "${CID}"
    harness_finish "tests/apk/upgrade-downgrade.sh"
fi
NATIVE_ARCH_LINE=$(docker exec "${CID}" cat /etc/apk/arch)
docker exec "${CID}" sh -c "printf '%s\n%s\n' '${NATIVE_ARCH_LINE}' '${ARCH}' > /etc/apk/arch"
docker exec "${CID}" sh -c "rm -f /etc/apk/repositories.d/*.list"

# --- lay down the real ipk payload at its real on-device paths ----------
docker cp "${WORKDIR}/ipk-extract/data/." "${CID}:/"

# --- run the real postinst LIVE (IPKG_INSTROOT unset) to create real
# network/firewall UCI state -- this is genuinely what `opkg install`
# itself would have run. -----------------------------------------------
docker cp "${WORKDIR}/ipk-extract/control/postinst" "${CID}:/tmp/tailscale.postinst"
docker exec "${CID}" chmod 755 /tmp/tailscale.postinst
POSTINST_OUT=$(docker exec "${CID}" sh -c '/tmp/tailscale.postinst 2>&1') || true
echo "postinst (live, simulating the original opkg install): ${POSTINST_OUT}"

# --- simulate a killswitch-enabled DNS redirect: the RFC's own concrete
# example of state "only an ipk postrm would clean up" (tailscale.postrm's
# DNS_BACKUP handling) -- so there is genuine orphan-able state to assert
# against below, not just inert files. -----------------------------------
#
# M8: seed a REAL pre-existing multi-value DNS server list (the router's
# actual original config, before the killswitch ever touched it) so the
# dns_backup captured below has known, asserted-against content -- not
# whatever the rootfs image happened to ship by default. postrm's restore
# is asserted (further down) to reproduce this exact list, not just "not
# still pointing at MagicDNS".
ORIGINAL_DNS_SERVERS="8.8.8.8 1.1.1.1"
docker exec "${CID}" sh -c "
    uci -q delete dhcp.@dnsmasq[0].server
    uci add_list dhcp.@dnsmasq[0].server='8.8.8.8'
    uci add_list dhcp.@dnsmasq[0].server='1.1.1.1'
    uci commit dhcp
"
docker exec "${CID}" mkdir -p /etc/tailscale
docker exec "${CID}" sh -c "uci -q get dhcp.@dnsmasq[0].server > /etc/tailscale/dns_backup 2>/dev/null; true"
docker exec "${CID}" sh -c "
    uci -q delete dhcp.@dnsmasq[0].server
    uci add_list dhcp.@dnsmasq[0].server='100.100.100.100'
    uci set dhcp.@dnsmasq[0].noresolv='1'
    uci commit dhcp
"

# --- construct opkg's own bookkeeping (info dir + status stanza) --------
# This is the actual marker apk_path()'s opkg_tracked_tailscale() keys off
# -- filesystem-level, not `opkg list-installed` (confirmed this slice:
# the pinned 25.12 rootfs ships no opkg binary at all).
docker exec "${CID}" mkdir -p /usr/lib/opkg/info
docker cp "${WORKDIR}/ipk-extract/control/control" "${CID}:/usr/lib/opkg/info/tailscale.control"
docker cp "${WORKDIR}/ipk-extract/control/conffiles" "${CID}:/usr/lib/opkg/info/tailscale.conffiles"
docker cp "${WORKDIR}/ipk-extract/control/postinst" "${CID}:/usr/lib/opkg/info/tailscale.postinst"
docker cp "${WORKDIR}/ipk-extract/control/prerm" "${CID}:/usr/lib/opkg/info/tailscale.prerm"
docker cp "${WORKDIR}/ipk-extract/control/postrm" "${CID}:/usr/lib/opkg/info/tailscale.postrm"
docker cp "${WORKDIR}/ipk-extract/tailscale.list" "${CID}:/usr/lib/opkg/info/tailscale.list"
docker exec "${CID}" chmod 755 /usr/lib/opkg/info/tailscale.postinst /usr/lib/opkg/info/tailscale.prerm /usr/lib/opkg/info/tailscale.postrm
docker exec "${CID}" sh -c "printf 'Package: tailscale\nVersion: %s\nStatus: install user installed\nArchitecture: %s\n\n' '${TEST_VERSION}-${TEST_PKG_RELEASE}' '${ARCH}' >> /usr/lib/opkg/status"

# --- RED baseline: confirm the simulated stale-ipk footprint is really
# there before we touch it (meaningless assertions otherwise). -----------
BASELINE_FAIL=0
if ! docker exec "${CID}" test -f /usr/lib/opkg/info/tailscale.control; then BASELINE_FAIL=1; fi
if ! docker exec "${CID}" test -f /etc/tailscale/dns_backup; then BASELINE_FAIL=1; fi
if ! docker exec "${CID}" test -x /usr/sbin/tailscaled; then BASELINE_FAIL=1; fi
NORESOLV_BASELINE=$(docker exec "${CID}" sh -c "uci -q get dhcp.@dnsmasq[0].noresolv" || echo "")
if [ "${NORESOLV_BASELINE}" != "1" ]; then BASELINE_FAIL=1; fi
DNS_BACKUP_BASELINE=$(docker exec "${CID}" sh -c "tr '\n' ' ' < /etc/tailscale/dns_backup 2>/dev/null | sed 's/[[:space:]]*\$//'" || echo "")
if [ "${DNS_BACKUP_BASELINE}" != "${ORIGINAL_DNS_SERVERS}" ]; then BASELINE_FAIL=1; fi
if [ "${BASELINE_FAIL}" -eq 1 ]; then
    log_fail "Part A: RED baseline: simulated stale-ipk footprint not fully in place before the apk install"
else
    log_info "OK: Part A: RED baseline: stale ipk footprint in place (opkg info files, dns_backup, killswitch noresolv, payload)"
fi

# --- sign a feed for the current version + serve it, mirroring
# install-dispatch.sh's Part 4 (direct-openssl-sign simplification -- the
# imprimatur round trip itself is C2's job, already proven end-to-end). ---
mkdir -p "${WORKDIR}/idx"
IDX_CID=$(docker create "${BUILD_IMAGE_TAG}" sh -c "sleep 600")
track "${IDX_CID}"
docker start "${IDX_CID}" >/dev/null
docker exec "${IDX_CID}" mkdir -p /idx
docker cp "${WORKDIR}/repo/tailscale-${EXPECT_VERSION}.apk" "${IDX_CID}:/idx/"
docker cp "${WORKDIR}/stubrepo/." "${IDX_CID}:/idx/"
docker exec "${IDX_CID}" sh -c "rm -f /idx/packages.adb"
docker exec "${IDX_CID}" sh -c "apk mkndx --allow-untrusted --compression none --output /idx/packages.adb /idx/*.apk"
docker cp "${IDX_CID}:/idx/." "${WORKDIR}/idx/"
untrack_and_remove "${IDX_CID}"

mkdir -p "${WORKDIR}/keys"
openssl ecparam -genkey -name prime256v1 -noout -out "${WORKDIR}/keys/key.pem" 2>/dev/null
openssl ec -in "${WORKDIR}/keys/key.pem" -pubout -out "${WORKDIR}/keys/pub.pem" 2>/dev/null
python3 "${ADB_SIGN_PY}" preimage "${WORKDIR}/idx/packages.adb" "${WORKDIR}/keys/pub.pem" "${WORKDIR}/preimage.bin"
openssl dgst -sha512 -sign "${WORKDIR}/keys/key.pem" -out "${WORKDIR}/sig.der" "${WORKDIR}/preimage.bin"
mkdir -p "${WORKDIR}/served"
python3 "${ADB_SIGN_PY}" assemble "${WORKDIR}/idx/packages.adb" "${WORKDIR}/keys/pub.pem" "${WORKDIR}/sig.der" "${WORKDIR}/served/packages.adb"
for f in "${WORKDIR}"/idx/*.apk; do cp "$f" "${WORKDIR}/served/"; done

SERVE_ROOT="${WORKDIR}/serveroot"
mkdir -p "${SERVE_ROOT}/apk/${ARCH}" "${SERVE_ROOT}/apk/keys"
cp "${WORKDIR}/served/"* "${SERVE_ROOT}/apk/${ARCH}/"
cp "${WORKDIR}/keys/pub.pem" "${SERVE_ROOT}/apk/keys/tailscale.pem"

PORT=18877
( cd "${SERVE_ROOT}" && exec python3 -m http.server "${PORT}" >"${WORKDIR}/httpd.log" 2>&1 ) &
SRV_PIDS="${SRV_PIDS} $!"
_i=0
while [ "${_i}" -lt 20 ]; do
    if curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/apk/${ARCH}/packages.adb" 2>/dev/null; then break; fi
    _i=$((_i + 1)); sleep 0.25
done
echo "OK: serving the signed feed on 127.0.0.1:${PORT}"

# --- run install.sh's OWN apk_path() (real dispatch: real
# /etc/openwrt_release from the rootfs, not a forced path) against the
# stale-ipk container. THIS is the load-bearing step -- the preflight
# lives in install.sh/lib-install.sh, not in this test. -------------------
#
# H2: install.sh's apk_path() pins the feed signing key's SHA256
# (APK_FEED_KEY_SHA256, checked against the real committed apk-signing.pem)
# instead of the old openssl-based check. This test signs the feed with a
# FRESH ephemeral key every run (the real private key lives only on
# sign.leavitt.info, per the imprimatur signing service -- this test never
# has it), so the shipped hardcoded pin can never match here. Patch a
# throwaway copy of install.sh with THIS run's own key's SHA256 before
# copying it in -- this substitutes only the expected-hash constant for
# test purposes; every other line (the actual dispatch/adapter code under
# test) is untouched, mirroring how APK_FEED_SCHEME/APK_FEED_HOST are
# already overridden via env vars for the same reason.
TEST_KEY_SHA256=$(sha256sum "${WORKDIR}/keys/pub.pem" | awk '{print $1}')
sed "s/^APK_FEED_KEY_SHA256=.*/APK_FEED_KEY_SHA256=\"${TEST_KEY_SHA256}\"/" \
    "${INSTALL_DIR}/install.sh" > "${WORKDIR}/install.sh.patched"
if ! grep -qF "APK_FEED_KEY_SHA256=\"${TEST_KEY_SHA256}\"" "${WORKDIR}/install.sh.patched"; then
    log_fail "Part A: failed to patch install.sh's APK_FEED_KEY_SHA256 for the test's ephemeral key (install.sh's constant format may have changed)"
    harness_finish "tests/apk/upgrade-downgrade.sh"
fi
# `sed > file` creates a fresh, non-executable file -- unlike a plain
# `docker cp` of install.sh itself, which preserves the source's own +x
# bit. Restore it, or install.sh runs as `env: can't execute ...
# Permission denied` inside the container.
chmod 755 "${WORKDIR}/install.sh.patched"

docker exec "${CID}" mkdir -p /opt/install-test
docker cp "${WORKDIR}/install.sh.patched" "${CID}:/opt/install-test/install.sh"
docker cp "${INSTALL_DIR}/lib-install.sh" "${CID}:/opt/install-test/lib-install.sh"

echo "=== install.sh (ipk -> apk coexistence) ==="
if INSTALL_OUT=$(exec_in_container "${CID}" env \
        APK_FEED_SCHEME=http "APK_FEED_HOST=127.0.0.1:${PORT}" AUTO_YES=true \
        sh /opt/install-test/install.sh -y); then
    echo "${INSTALL_OUT}"
    log_info "OK: install.sh's apk path completed against the stale-ipk container"
else
    echo "${INSTALL_OUT}"
    log_fail "Part A: install.sh's apk path FAILED against the stale-ipk container"
fi

# --- assertions: no residual/duplicate opkg-tracked state ---------------
if docker exec "${CID}" test -e /usr/lib/opkg/info/tailscale.control 2>/dev/null; then
    log_fail "Part A: /usr/lib/opkg/info/tailscale.control still present after the apk install (dual-tracked)"
else
    log_info "OK: Part A: no residual /usr/lib/opkg/info/tailscale.control"
fi
_residual_info=0
for _f in list conffiles postinst prerm postrm; do
    if docker exec "${CID}" test -e "/usr/lib/opkg/info/tailscale.${_f}" 2>/dev/null; then
        log_fail "Part A: /usr/lib/opkg/info/tailscale.${_f} still present after the apk install"
        _residual_info=1
    fi
done
if [ "${_residual_info}" -eq 0 ]; then
    log_info "OK: Part A: no residual /usr/lib/opkg/info/tailscale.{list,conffiles,postinst,prerm,postrm}"
fi

STATUS_OUT=$(docker exec "${CID}" sh -c 'grep -c "^Package: tailscale$" /usr/lib/opkg/status 2>/dev/null || true')
[ -z "${STATUS_OUT}" ] && STATUS_OUT=0
assert_eq "Part A: opkg status has no leftover 'Package: tailscale' stanza" "0" "${STATUS_OUT}"

if docker exec "${CID}" test -e /etc/tailscale/dns_backup 2>/dev/null; then
    log_fail "Part A: /etc/tailscale/dns_backup still present -- orphaned killswitch DNS state was never cleaned up (the ipk postrm's job)"
else
    log_info "OK: Part A: killswitch DNS backup was processed/removed (postrm ran)"
fi

NORESOLV_AFTER=$(docker exec "${CID}" sh -c "uci -q get dhcp.@dnsmasq[0].noresolv" 2>/dev/null || echo "")
assert_not_contains "Part A: killswitch DNS redirect (noresolv) was restored, not left dangling" "${NORESOLV_AFTER}" "1"

# M8: postrm must restore the router's exact original multi-value DNS
# server list (seeded above as ORIGINAL_DNS_SERVERS), not just "something
# other than noresolv=1/MagicDNS". uci prints one list value per line;
# normalize to a single space-joined string for a clean comparison.
DNS_SERVERS_AFTER=$(docker exec "${CID}" sh -c "uci -q get dhcp.@dnsmasq[0].server" 2>/dev/null || echo "")
DNS_SERVERS_AFTER_NORM=$(echo "${DNS_SERVERS_AFTER}" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
assert_eq "Part A: postrm restored the router's exact original multi-value DNS server list (M8)" "${ORIGINAL_DNS_SERVERS}" "${DNS_SERVERS_AFTER_NORM}"

if exec_in_container "${CID}" apk info -e tailscale >/dev/null; then
    log_info "OK: Part A: apk now cleanly owns tailscale"
else
    log_fail "Part A: apk does not report tailscale as installed after install.sh's apk path ran"
fi

if VERSION_OUT=$(exec_in_container "${CID}" /usr/sbin/tailscaled --version); then
    assert_contains "Part A: tailscaled --version reports the freshly apk-installed version" "${VERSION_OUT}" "${TEST_VERSION}"
else
    log_fail "Part A: tailscaled --version failed to execute after the apk install (${VERSION_OUT})"
fi

untrack_and_remove "${CID}"
for p in ${SRV_PIDS}; do kill "$p" >/dev/null 2>&1 || true; done
SRV_PIDS=""
fi

# =====================================================================
# Part B -- tested downgrade (docs/INSTALL.md "Downgrading (apk)")
# =====================================================================
if [ "${RUN_DOWNGRADE}" -eq 1 ]; then
echo ""
echo "############################################"
echo "### Part B: tested downgrade (real version delta, ${EXPECT_VERSION} -> ${EXPECT_OLD_VERSION})"
echo "############################################"

OLD_BUILD_IMAGE_TAG="tailscale-apk-upgradedowngrade-old:${ARCH}"
docker build \
    --target apk \
    --build-arg TAILSCALE_VERSION="${OLD_VERSION}" \
    --build-arg PKG_RELEASE="${OLD_PKG_RELEASE}" \
    --build-arg OPENWRT_ARCH="${ARCH}" \
    --build-arg SKIP_UPX=1 \
    -t "${OLD_BUILD_IMAGE_TAG}" -f "${PKG_DIR}/Dockerfile" "${PKG_DIR}"

OCID=$(docker create "${OLD_BUILD_IMAGE_TAG}")
track "${OCID}"
docker cp "${OCID}:/out/${ARCH}/tailscale-${EXPECT_OLD_VERSION}.apk" "${WORKDIR}/repo/"
untrack_and_remove "${OCID}"
if [ ! -s "${WORKDIR}/repo/tailscale-${EXPECT_OLD_VERSION}.apk" ]; then
    log_fail "Part B: older .apk missing/empty after extraction"
    harness_finish "tests/apk/upgrade-downgrade.sh"
fi
echo "OK: built tailscale-${EXPECT_OLD_VERSION}.apk (real version delta: ${TEST_VERSION} -> ${OLD_VERSION})"

DCID=$(docker create --network none "${ROOTFS_IMAGE_TAG}" sh -c "sleep 600")
track "${DCID}"
docker start "${DCID}" >/dev/null
if ! exec_in_container "${DCID}" apk --print-arch >/dev/null; then
    log_fail "Part B: apk --print-arch failed in target container"
    untrack_and_remove "${DCID}"
    harness_finish "tests/apk/upgrade-downgrade.sh"
fi
NATIVE_ARCH_LINE=$(docker exec "${DCID}" cat /etc/apk/arch)
docker exec "${DCID}" sh -c "printf '%s\n%s\n' '${NATIVE_ARCH_LINE}' '${ARCH}' > /etc/apk/arch"

docker exec "${DCID}" mkdir -p /stubrepo
docker cp "${WORKDIR}/stubrepo/." "${DCID}:/stubrepo/"
docker cp "${WORKDIR}/repo/tailscale-${EXPECT_VERSION}.apk" "${DCID}:/tailscale-new.apk"
docker cp "${WORKDIR}/repo/tailscale-${EXPECT_OLD_VERSION}.apk" "${DCID}:/tailscale-old.apk"

# --- 1. provision the NEWER version first (offline local-file install,
# the same mechanism A4/A5b established for a dependency-incomplete
# offline container). ------------------------------------------------
echo "=== provisioning the newer version (${EXPECT_VERSION}) ==="
if ! NEW_OUT=$(exec_in_container "${DCID}" \
        apk add --allow-untrusted --force-missing-repositories \
        -X /stubrepo/packages.adb /tailscale-new.apk); then
    echo "${NEW_OUT}"
    log_fail "Part B: provisioning the newer version failed"
    untrack_and_remove "${DCID}"
    harness_finish "tests/apk/upgrade-downgrade.sh"
fi
echo "${NEW_OUT}"
if VERSION_BEFORE=$(exec_in_container "${DCID}" /usr/sbin/tailscaled --version); then
    assert_contains "Part B: newer version provisioned correctly" "${VERSION_BEFORE}" "${TEST_VERSION}"
else
    log_fail "Part B: tailscaled --version failed to execute after provisioning the newer version"
fi

# --- 2. the EXACT documented downgrade command (docs/INSTALL.md
# "Downgrading (apk)"): `apk add --allow-untrusted ./<old>.apk`, nothing
# else. This is the load-bearing assertion of this slice's §4.7 half. ----
echo "=== apk add --allow-untrusted ./tailscale-old.apk (exact documented command) ==="
DOWNGRADE_OK=1
if ! DOWNGRADE_OUT=$(docker exec "${DCID}" sh -c "cd / && apk add --allow-untrusted ./tailscale-old.apk" 2>&1); then
    DOWNGRADE_OK=0
fi
echo "${DOWNGRADE_OUT}"

if [ "${DOWNGRADE_OK}" -eq 1 ]; then
    log_info "OK: Part B: the documented 'apk add --allow-untrusted ./<old>.apk' command succeeded as-is"
    assert_contains "Part B: apk's own transaction log reports a real downgrade" "${DOWNGRADE_OUT}" "Downgrading tailscale"
else
    log_fail "Part B: the documented downgrade command FAILED -- docs/INSTALL.md would need updating (see script output above for the real apk error)"
fi

if VERSION_AFTER=$(exec_in_container "${DCID}" /usr/sbin/tailscaled --version); then
    assert_contains "Part B: tailscaled --version reports the OLDER version after the documented downgrade command" "${VERSION_AFTER}" "${OLD_VERSION}"
else
    log_fail "Part B: tailscaled --version failed to execute after the downgrade attempt"
fi

if exec_in_container "${DCID}" apk info -e tailscale >/dev/null; then
    ADB_VER=$(docker exec "${DCID}" sh -c "apk list -I 2>/dev/null | grep '^tailscale-'")
    assert_contains "Part B: apk's own package db reports the older version installed" "${ADB_VER}" "${EXPECT_OLD_VERSION}"
fi

untrack_and_remove "${DCID}"
fi

harness_finish "tests/apk/upgrade-downgrade.sh"
