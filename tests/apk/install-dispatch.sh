#!/bin/sh
# tests/apk/install-dispatch.sh
#
# Slice D1 test (RFC docs/rfc-apk-builds.md §4.4, §6 slice D1): proves
# scripts/install.sh is a real dispatcher over SHARED primitives
# (scripts/lib-install.sh), not a three-way if/elif reimplementing
# detect_arch/prompt_confirm/poll_for_service/log_* per path -- and that
# its apk adapter genuinely ends with a TRUSTED `apk add tailscale` (no
# --allow-untrusted) against a real served, signed feed.
#
# Four parts, in order:
#
#   1. Release-detection failure path -- detect_release()/choose_path()
#      against missing and malformed /etc/openwrt_release fixtures (via
#      the OPENWRT_RELEASE_FILE override), asserting graceful fallback
#      (never a crash, never a silent wrong-path pick).
#   2. <=24.10 path -- choose_path() against a 24.10 fixture, and
#      separately a 25.12 fixture with `apk` absent from PATH, both must
#      land on "ipk" and print a clear hint -- NEVER the raw
#      "command not found" shell error apk_path() would produce if called
#      with apk missing and no guard.
#   3. Primitive-sharing / structural check -- greps the whole repo for
#      each primitive's function definition and asserts exactly ONE
#      authored copy exists (in scripts/lib-install.sh); asserts
#      install.sh's ipk/apk paths reference the shared calls; asserts
#      install.sh's glinet path delegates (no GL-specific mechanics
#      duplicated into this file).
#   4. Trusted apk install, for real -- builds the real aarch64 .apk +
#      three offline stub deps (kmod-tun/ip-full/conntrack, the
#      A4/A5b/C2 trick) into ONE combined index, signs it with a fresh
#      local EC key via `openssl dgst -sha512 -sign` (the same
#      EVP_DigestSign(sha512)->DER byte path imprimatur's /sign/ec uses,
#      B0 spike -- reusing tests/apk/feed-publish.sh's own established
#      simplification of signing directly rather than re-standing-up a
#      CI-local imprimatur container: THAT round trip is already
#      hermetically proven end-to-end by tests/apk/sign-verify.sh (C2);
#      this slice's job is to prove install.sh's DISPATCH+ADAPTER code
#      runs the right commands against a served feed, not to re-prove the
#      signing pipeline). Serves the signed tree over plain HTTP via
#      `python3 -m http.server`, copies install.sh + lib-install.sh into
#      the pinned OpenWrt 25.12 aarch64 rootfs container (real
#      /etc/openwrt_release -- real dispatch, not forced), points
#      APK_FEED_SCHEME/APK_FEED_HOST at the served feed, and asserts a
#      plain `apk add tailscale` via install.sh's own apk_path() --
#      NOT --allow-untrusted anywhere -- succeeds and installs the real
#      binary.
#
# Uses the shared tests/apk/lib.sh harness. Never commits/pushes anything;
# the ephemeral test key lives only in a mktemp scratch dir.
#
# Usage:
#   sh tests/apk/install-dispatch.sh          # all 4 parts
#   sh tests/apk/install-dispatch.sh --unit-only   # skip the docker part

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
INSTALL_DIR="${REPO_ROOT}/scripts"
PKG_DIR="${REPO_ROOT}/tailscale-package"
ARCHES_JSON="${REPO_ROOT}/arches.json"
ADB_SIGN_PY="${REPO_ROOT}/scripts/adb-sign.py"
CACHE_DIR="${ROOTFS_CACHE_DIR:-${SCRIPT_DIR}/.cache}"

# shellcheck source=tests/apk/lib.sh
. "${SCRIPT_DIR}/lib.sh"

require_cmd jq

RUN_DOCKER=1
if [ "${1:-}" = "--unit-only" ]; then
    RUN_DOCKER=0
fi

if [ ! -f "${INSTALL_DIR}/install.sh" ]; then
    echo "FAIL: scripts/install.sh not found" >&2
    exit 1
fi
if [ ! -f "${INSTALL_DIR}/lib-install.sh" ]; then
    echo "FAIL: scripts/lib-install.sh not found" >&2
    exit 1
fi

WORKDIR=$(mktemp -d)
CLEANUP_CIDS=""
SRV_PID=""
cleanup() {
    for c in ${CLEANUP_CIDS}; do
        docker rm -f "${c}" >/dev/null 2>&1 || true
    done
    if [ -n "${SRV_PID}" ]; then
        kill "${SRV_PID}" >/dev/null 2>&1 || true
    fi
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT
track() { CLEANUP_CIDS="${CLEANUP_CIDS} $1"; }
untrack_and_remove() {
    docker rm -f "$1" >/dev/null 2>&1 || true
    CLEANUP_CIDS=$(echo "${CLEANUP_CIDS}" | sed "s/$1//")
}

# =====================================================================
# Part 1 -- release-detection failure path
# =====================================================================
echo ""
echo "############################################"
echo "### Part 1: release-detection failure path"
echo "############################################"

mkdir -p "${WORKDIR}/fixtures"
cat > "${WORKDIR}/fixtures/release-2512" <<'EOF'
DISTRIB_ID='OpenWrt'
DISTRIB_RELEASE='25.12.0'
DISTRIB_REVISION='r0'
DISTRIB_TARGET='armsr/armv8'
DISTRIB_DESCRIPTION='OpenWrt 25.12.0'
EOF
cat > "${WORKDIR}/fixtures/release-2410" <<'EOF'
DISTRIB_ID='OpenWrt'
DISTRIB_RELEASE='24.10.1'
DISTRIB_REVISION='r0'
EOF
cat > "${WORKDIR}/fixtures/release-malformed" <<'EOF'
FOO='bar'
EOF

mkdir -p "${WORKDIR}/fake-apk-bin"
cat > "${WORKDIR}/fake-apk-bin/apk" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "${WORKDIR}/fake-apk-bin/apk"

run_choose_path() {
    # run_choose_path release_file path_extra -- sources install.sh in
    # test mode with the given OPENWRT_RELEASE_FILE and PATH prefix, prints
    # choose_path()'s stdout choice, and separately captures stderr.
    _rel="$1"
    _pathextra="$2"
    (
        INSTALL_SH_NO_MAIN=1
        export INSTALL_SH_NO_MAIN
        SCRIPT_DIR="${INSTALL_DIR}"
        export SCRIPT_DIR
        OPENWRT_RELEASE_FILE="${_rel}"
        export OPENWRT_RELEASE_FILE
        if [ -n "${_pathextra}" ]; then
            PATH="${_pathextra}:${PATH}"
            export PATH
        else
            PATH="/usr/bin:/bin"
            export PATH
        fi
        . "${INSTALL_DIR}/install.sh"
        choose_path
    )
}

# (a) missing file entirely
CHOICE=$(run_choose_path "${WORKDIR}/fixtures/does-not-exist" "${WORKDIR}/fake-apk-bin" 2>"${WORKDIR}/p1-missing.err") || true
assert_eq "missing /etc/openwrt_release: falls back to ipk" "ipk" "${CHOICE}"
assert_contains "missing /etc/openwrt_release: warns, doesn't crash" "$(cat "${WORKDIR}/p1-missing.err")" "Could not detect OpenWrt release"

# (b) present but malformed (no DISTRIB_RELEASE)
CHOICE=$(run_choose_path "${WORKDIR}/fixtures/release-malformed" "${WORKDIR}/fake-apk-bin" 2>"${WORKDIR}/p1-malformed.err") || true
assert_eq "malformed /etc/openwrt_release: falls back to ipk" "ipk" "${CHOICE}"
assert_contains "malformed /etc/openwrt_release: warns, doesn't crash" "$(cat "${WORKDIR}/p1-malformed.err")" "Could not detect OpenWrt release"

# RED-proof control: a WELL-FORMED release file must NOT hit the
# failure-path message (proves the assertions above aren't vacuous).
CHOICE=$(run_choose_path "${WORKDIR}/fixtures/release-2410" "${WORKDIR}/fake-apk-bin" 2>"${WORKDIR}/p1-control.err") || true
assert_not_contains "control: well-formed release file does NOT hit the failure path" "$(cat "${WORKDIR}/p1-control.err")" "Could not detect OpenWrt release"

# =====================================================================
# Part 2 -- <=24.10 path prints the ipk hint, never "command not found"
# =====================================================================
echo ""
echo "############################################"
echo "### Part 2: <=24.10 / apk-absent -> ipk hint"
echo "############################################"

# (a) release itself is <=24.10 (apk genuinely wouldn't exist on such a
# system) -- apk never on PATH at all here.
CHOICE=$(run_choose_path "${WORKDIR}/fixtures/release-2410" "" 2>"${WORKDIR}/p2-2410.err") || true
assert_eq "OpenWrt 24.10: dispatches to ipk" "ipk" "${CHOICE}"
assert_contains "OpenWrt 24.10: prints an ipk hint" "$(cat "${WORKDIR}/p2-2410.err")" "ipk path"
assert_not_contains "OpenWrt 24.10: never a raw 'command not found'" "$(cat "${WORKDIR}/p2-2410.err")" "command not found"

# (b) release LOOKS like 25.12+ but `apk` is missing from PATH (e.g. a
# broken/nonstandard image) -- must still fall back with a clear hint, not
# whatever raw error a bare `apk ...` invocation would produce.
CHOICE=$(run_choose_path "${WORKDIR}/fixtures/release-2512" "" 2>"${WORKDIR}/p2-noapk.err") || true
assert_eq "OpenWrt 25.12 + apk absent: dispatches to ipk" "ipk" "${CHOICE}"
assert_contains "OpenWrt 25.12 + apk absent: explains apk was not found" "$(cat "${WORKDIR}/p2-noapk.err")" "'apk' was not found on PATH"
assert_contains "OpenWrt 25.12 + apk absent: still points at the ipk path" "$(cat "${WORKDIR}/p2-noapk.err")" "ipk path"
assert_not_contains "OpenWrt 25.12 + apk absent: never a raw 'command not found'" "$(cat "${WORKDIR}/p2-noapk.err")" "command not found"

# (c) also exercise apk_path()'s OWN guard directly (defense in depth: even
# if something forced the apk path with apk missing, e.g. --path apk on a
# <=24.10 box, the adapter itself must still produce the clear hint, not a
# raw "apk: command not found" from the shell trying to exec a
# nonexistent binary).
APK_PATH_OUT=$(
    (
        INSTALL_SH_NO_MAIN=1
        export INSTALL_SH_NO_MAIN
        SCRIPT_DIR="${INSTALL_DIR}"
        export SCRIPT_DIR
        PATH="/usr/bin:/bin"
        export PATH
        . "${INSTALL_DIR}/install.sh"
        apk_path 2>&1
    )
) || true
assert_contains "apk_path() itself hints at ipk when apk is missing" "${APK_PATH_OUT}" "apk-tools ships only on OpenWrt 25.12+"
assert_not_contains "apk_path() itself never surfaces a raw 'command not found'" "${APK_PATH_OUT}" "command not found"

# =====================================================================
# Part 3 -- primitive-sharing / structural check
# =====================================================================
echo ""
echo "############################################"
echo "### Part 3: primitive-sharing / structural check"
echo "############################################"

count_def() {
    # count_def funcname -- number of files under scripts/ that define
    # this function (grep -l, not -c, so a file defining it twice --
    # itself a bug -- doesn't over/undercount file-level duplication).
    grep -rl "^$1() {" "${REPO_ROOT}/scripts"/*.sh 2>/dev/null | wc -l | tr -d ' '
}

for fn in detect_arch prompt_confirm poll_for_service log_info log_warn log_error detect_release get_latest_version; do
    N=$(count_def "${fn}")
    assert_eq "exactly one authored definition of ${fn}() in scripts/*.sh" "1" "${N}"
    OWNER=$(grep -l "^${fn}() {" "${REPO_ROOT}/scripts"/*.sh 2>/dev/null | xargs -n1 basename)
    assert_eq "${fn}() is defined in lib-install.sh (not copy-pasted elsewhere)" "lib-install.sh" "${OWNER}"
done

# install.sh must source the shared module (not redefine it) for its own
# ipk/apk paths -- and each of those two adapters must actually call at
# least the arch + service-poll primitives (proving they're USED, not
# just present in the file somewhere irrelevant).
assert_contains "install.sh sources lib-install.sh (local-sibling branch)" \
    "$(cat "${INSTALL_DIR}/install.sh")" '. "${SCRIPT_DIR}/lib-install.sh"'

IPK_BODY=$(awk '/^ipk_path\(\) \{/,/^}/' "${INSTALL_DIR}/install.sh")
assert_contains "ipk_path() calls the shared detect_arch" "${IPK_BODY}" "detect_arch"
assert_contains "ipk_path() calls the shared poll_for_service" "${IPK_BODY}" "poll_for_service tailscaled 30"
assert_contains "ipk_path() calls the shared should_reinstall/prompt_confirm path" "${IPK_BODY}" "should_reinstall"

APK_BODY=$(awk '/^apk_path\(\) \{/,/^}/' "${INSTALL_DIR}/install.sh")
assert_contains "apk_path() calls the shared detect_arch" "${APK_BODY}" "detect_arch"
assert_contains "apk_path() calls the shared poll_for_service" "${APK_BODY}" "poll_for_service tailscaled 30"
assert_contains "apk_path() calls the shared should_reinstall/prompt_confirm path" "${APK_BODY}" "should_reinstall"
# Check the actual `apk add`/`apk update` invocation lines specifically
# (not just "does the file mention the string anywhere" -- apk_path()'s own
# log message legitimately SAYS "no --allow-untrusted" in prose, which a
# naive whole-body substring check would wrongly flag).
APK_INVOCATION_LINES=$(echo "${APK_BODY}" | grep -E '^\s*(if !? ?)?apk (add|update)\b')
assert_not_contains "apk_path()'s actual apk add/update invocations never pass --allow-untrusted" \
    "${APK_INVOCATION_LINES}" "allow-untrusted"

GLINET_BODY=$(awk '/^glinet_path\(\) \{/,/^}/' "${INSTALL_DIR}/install.sh")
assert_not_contains "glinet_path() does not duplicate GL binary-swap mechanics (no gl_tailscale calls)" "${GLINET_BODY}" "gl_tailscale stop"
assert_not_contains "glinet_path() does not redefine detect_arch itself" "${GLINET_BODY}" "detect_arch()"
assert_contains "glinet_path() delegates to install-glinet.sh" "${GLINET_BODY}" "install-glinet.sh"

# install-glinet.sh: confirm it now SOURCES the shared module rather than
# carrying its own inline copies (the actual D1 refactor, not just a new
# install.sh sitting next to the old duplication).
assert_contains "install-glinet.sh sources lib-install.sh too" \
    "$(cat "${INSTALL_DIR}/install-glinet.sh")" '. "${SCRIPT_DIR}/lib-install.sh"'
assert_not_contains "install-glinet.sh no longer defines its own detect_arch" \
    "$(cat "${INSTALL_DIR}/install-glinet.sh")" 'detect_arch() {'
assert_not_contains "install-glinet.sh no longer defines its own log_info" \
    "$(cat "${INSTALL_DIR}/install-glinet.sh")" 'log_info() {'

harness_finish "tests/apk/install-dispatch.sh (parts 1-3, unit/structural)"

if [ "${RUN_DOCKER}" -eq 0 ]; then
    echo "--unit-only requested: skipping Part 4 (docker trusted-install)"
    exit 0
fi

require_cmd docker
require_cmd openssl
require_cmd curl
require_cmd python3

# =====================================================================
# Part 4 -- trusted apk install, for real, via install.sh's own apk_path()
# =====================================================================
echo ""
echo "############################################"
echo "### Part 4: trusted apk install (real container, real signed feed)"
echo "############################################"

TEST_VERSION="${INSTALL_DISPATCH_TEST_VERSION:-1.92.2}"
TEST_PKG_RELEASE="${INSTALL_DISPATCH_TEST_PKG_RELEASE:-1}"
EXPECT_VERSION="${TEST_VERSION}-r${TEST_PKG_RELEASE}"
ARCH="aarch64_cortex-a53"

if [ ! -f "${PKG_DIR}/Dockerfile" ]; then
    echo "FAIL: ${PKG_DIR}/Dockerfile not found" >&2
    exit 1
fi

URL=$(jq -r --arg n "${ARCH}" '.[] | select(.name==$n) | .rootfs_url' "${ARCHES_JSON}")
PIN=$(jq -r --arg n "${ARCH}" '.[] | select(.name==$n) | .rootfs_sha256' "${ARCHES_JSON}")
ROOTFS_IMAGE_TAG="owrt2512-rootfs:${ARCH}"
BUILD_IMAGE_TAG="tailscale-apk-installdispatch-build:${ARCH}"

mkdir -p "${CACHE_DIR}"
DEST="${CACHE_DIR}/$(basename "${URL}")"
if [ ! -f "${DEST}" ] || [ "$(sha256sum "${DEST}" | awk '{print $1}')" != "${PIN}" ]; then
    echo "Downloading ${URL}"
    curl -fsSL -o "${DEST}.part" "${URL}"
    mv "${DEST}.part" "${DEST}"
fi
ACTUAL=$(sha256sum "${DEST}" | awk '{print $1}')
if [ "${ACTUAL}" != "${PIN}" ]; then
    log_fail "rootfs sha256 mismatch for ${DEST} (expected ${PIN}, got ${ACTUAL})"
    harness_finish "tests/apk/install-dispatch.sh (part 4)"
fi
docker import "${DEST}" "${ROOTFS_IMAGE_TAG}" >/dev/null
echo "OK: rootfs sha256 verified + imported ${ROOTFS_IMAGE_TAG}"

echo "Building apk stage (arch=${ARCH}, version=${EXPECT_VERSION})..."
docker build \
    --target apk \
    --build-arg TAILSCALE_VERSION="${TEST_VERSION}" \
    --build-arg PKG_RELEASE="${TEST_PKG_RELEASE}" \
    --build-arg OPENWRT_ARCH="${ARCH}" \
    --build-arg SKIP_UPX=1 \
    -t "${BUILD_IMAGE_TAG}" -f "${PKG_DIR}/Dockerfile" "${PKG_DIR}"

BUILD_CID=$(docker create "${BUILD_IMAGE_TAG}")
track "${BUILD_CID}"
mkdir -p "${WORKDIR}/repo"
docker cp "${BUILD_CID}:/out/${ARCH}/tailscale-${EXPECT_VERSION}.apk" "${WORKDIR}/repo/"
untrack_and_remove "${BUILD_CID}"
if [ ! -s "${WORKDIR}/repo/tailscale-${EXPECT_VERSION}.apk" ]; then
    log_fail ".apk missing/empty after extraction"
    harness_finish "tests/apk/install-dispatch.sh (part 4)"
fi
echo "OK: built tailscale-${EXPECT_VERSION}.apk"

# combined index: real .apk + offline stub deps (A4/A5b/C2 trick -- ALL in
# one index since apk add has no per-repo trust flag).
IDX_CID=$(docker create "${BUILD_IMAGE_TAG}" sh -c "sleep 600")
track "${IDX_CID}"
docker start "${IDX_CID}" >/dev/null
docker exec "${IDX_CID}" mkdir -p /stubwork/empty /repo
docker cp "${WORKDIR}/repo/tailscale-${EXPECT_VERSION}.apk" "${IDX_CID}:/repo/"
for dep in kmod-tun ip-full conntrack; do
    docker exec "${IDX_CID}" sh -c \
        "apk mkpkg --allow-untrusted --info 'name:${dep}' --info 'version:1-r1' --info 'arch:${ARCH}' --files /stubwork/empty --output /repo/${dep}-1-r1.apk"
done
docker exec "${IDX_CID}" sh -c \
    "apk mkndx --allow-untrusted --compression none --output /repo/packages.adb /repo/*.apk"
docker cp "${IDX_CID}:/repo/." "${WORKDIR}/repo/"
untrack_and_remove "${IDX_CID}"
echo "OK: combined unsigned packages.adb built (tailscale + 3 stub deps)"

# Sign it for real (same EVP_DigestSign(sha512)->DER path B0/imprimatur
# use), via a fresh local EC key -- reusing tests/apk/feed-publish.sh's own
# established simplification of signing directly rather than re-standing-up
# a CI-local imprimatur container; that round trip is C2's job
# (tests/apk/sign-verify.sh), already hermetically proven.
mkdir -p "${WORKDIR}/keys"
openssl ecparam -genkey -name prime256v1 -noout -out "${WORKDIR}/keys/key.pem" 2>/dev/null
openssl ec -in "${WORKDIR}/keys/key.pem" -pubout -out "${WORKDIR}/keys/pub.pem" 2>/dev/null
python3 "${ADB_SIGN_PY}" preimage "${WORKDIR}/repo/packages.adb" "${WORKDIR}/keys/pub.pem" "${WORKDIR}/preimage.bin"
openssl dgst -sha512 -sign "${WORKDIR}/keys/key.pem" -out "${WORKDIR}/sig.der" "${WORKDIR}/preimage.bin"

mkdir -p "${WORKDIR}/served"
python3 "${ADB_SIGN_PY}" assemble "${WORKDIR}/repo/packages.adb" "${WORKDIR}/keys/pub.pem" "${WORKDIR}/sig.der" "${WORKDIR}/served/packages.adb"
for f in "${WORKDIR}"/repo/*.apk; do
    cp "$f" "${WORKDIR}/served/"
done
mkdir -p "${WORKDIR}/served-keys"
cp "${WORKDIR}/keys/pub.pem" "${WORKDIR}/served-keys/tailscale.pem"
MAGIC=$(head -c4 "${WORKDIR}/served/packages.adb")
assert_eq "signed feed index is the uncompressed 'ADB.' form" "ADB." "${MAGIC}"

# --- serve over plain HTTP, one port for the arch feed, one for keys/ -----
# (mirrors the real apk.leavitt.dev/apk/<arch> + apk.leavitt.dev/apk/keys
# layout closely enough for install.sh's apk_path() to exercise the real
# URL-building logic: <scheme>://<host>/apk/<arch> and
# <scheme>://<host>/apk/keys/tailscale.pem both need to resolve under the
# SAME host:port, so lay files out that way under one served root.)
SERVE_ROOT="${WORKDIR}/serveroot"
mkdir -p "${SERVE_ROOT}/apk/${ARCH}" "${SERVE_ROOT}/apk/keys"
cp "${WORKDIR}/served/"* "${SERVE_ROOT}/apk/${ARCH}/"
cp "${WORKDIR}/served-keys/tailscale.pem" "${SERVE_ROOT}/apk/keys/tailscale.pem"

PORT=18477
( cd "${SERVE_ROOT}" && exec python3 -m http.server "${PORT}" >"${WORKDIR}/httpd.log" 2>&1 ) &
SRV_PID=$!
_i=0
while [ "${_i}" -lt 20 ]; do
    if curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/apk/${ARCH}/packages.adb" 2>/dev/null; then break; fi
    _i=$((_i + 1)); sleep 0.25
done
echo "OK: serving the signed feed on 127.0.0.1:${PORT}"

# --- binfmt (aarch64 only needed here) ------------------------------------
register_standard_qemu_binfmt || echo "WARN: standard binfmt registration failed (continuing)" >&2

exec_in_container() {
    _cid="$1"; shift
    docker exec "${_cid}" "$@"
}

# --- 1. RED: install.sh's apk path against the UNSIGNED index must fail --
UNSIGNED_ROOT="${WORKDIR}/serveroot-unsigned"
mkdir -p "${UNSIGNED_ROOT}/apk/${ARCH}" "${UNSIGNED_ROOT}/apk/keys"
cp "${WORKDIR}/repo/"* "${UNSIGNED_ROOT}/apk/${ARCH}/"
cp "${WORKDIR}/keys/pub.pem" "${UNSIGNED_ROOT}/apk/keys/tailscale.pem"
UPORT=18478
( cd "${UNSIGNED_ROOT}" && exec python3 -m http.server "${UPORT}" >"${WORKDIR}/httpd-unsigned.log" 2>&1 ) &
SRV_PID2=$!
_i=0
while [ "${_i}" -lt 20 ]; do
    if curl -fsS -o /dev/null "http://127.0.0.1:${UPORT}/apk/${ARCH}/packages.adb" 2>/dev/null; then break; fi
    _i=$((_i + 1)); sleep 0.25
done

run_install_sh_apk_path() {
    # run_install_sh_apk_path label feed_port -- fresh container each time
    # (apk add mutates world state), real /etc/openwrt_release (no
    # OPENWRT_RELEASE_FILE override -- genuine dispatch through choose_path,
    # not a forced path), --network host so 127.0.0.1:<port> reaches the
    # host's python http.server, stock repositories.d entries removed for
    # hermetic determinism (production devices keep theirs -- install.sh
    # itself never touches those files, only customfeeds.list, so this is
    # a test-environment isolation step, not a codepath difference).
    _label="$1"; _port="$2"
    _cid=$(docker create --network host "${ROOTFS_IMAGE_TAG}" sh -c "sleep 600")
    track "${_cid}"
    docker start "${_cid}" >/dev/null

    if ! exec_in_container "${_cid}" apk --print-arch >/dev/null 2>&1; then
        log_fail "${_label}: apk --print-arch failed in target container"
        untrack_and_remove "${_cid}"
        return 1
    fi
    NATIVE_ARCH_LINE=$(docker exec "${_cid}" cat /etc/apk/arch)
    docker exec "${_cid}" sh -c "printf '%s\n%s\n' '${NATIVE_ARCH_LINE}' '${ARCH}' > /etc/apk/arch"
    docker exec "${_cid}" sh -c "rm -f /etc/apk/repositories.d/*.list"

    docker exec "${_cid}" mkdir -p /opt/install-test
    docker cp "${INSTALL_DIR}/install.sh" "${_cid}:/opt/install-test/install.sh"
    docker cp "${INSTALL_DIR}/lib-install.sh" "${_cid}:/opt/install-test/lib-install.sh"

    echo "=== install.sh (${_label}) ==="
    if OUT=$(docker exec \
            -e "APK_FEED_SCHEME=http" \
            -e "APK_FEED_HOST=127.0.0.1:${_port}" \
            -e "AUTO_YES=true" \
            "${_cid}" sh /opt/install-test/install.sh -y 2>&1); then
        echo "${OUT}"
        untrack_and_remove "${_cid}"
        return 0
    else
        echo "${OUT}"
        untrack_and_remove "${_cid}"
        return 1
    fi
}

if run_install_sh_apk_path "unsigned feed" "${UPORT}" >"${WORKDIR}/out-unsigned.log" 2>&1; then
    cat "${WORKDIR}/out-unsigned.log"
    log_fail "unsigned feed: install.sh's apk path unexpectedly SUCCEEDED (no --allow-untrusted was used, so this should have been rejected)"
else
    cat "${WORKDIR}/out-unsigned.log"
    log_info "OK: unsigned feed correctly rejected by install.sh's apk path (untrusted, no --allow-untrusted)"
fi
kill "${SRV_PID2}" >/dev/null 2>&1 || true

# --- 2. GREEN: the real, signed feed -- must succeed, trusted -----------
if run_install_sh_apk_path "signed feed (expect SUCCESS)" "${PORT}" >"${WORKDIR}/out-signed.log" 2>&1; then
    cat "${WORKDIR}/out-signed.log"
    log_info "OK: install.sh's apk path succeeded (trusted, no --allow-untrusted) against the signed feed"
    assert_contains "install.sh ran the apk path (dispatcher output)" "$(cat "${WORKDIR}/out-signed.log")" "Using the apk install path"
    assert_contains "install.sh added the feed to customfeeds.list" "$(cat "${WORKDIR}/out-signed.log")" "customfeeds.list"
    assert_contains "install.sh ran apk add tailscale (trusted)" "$(cat "${WORKDIR}/out-signed.log")" "apk add tailscale (trusted"
    assert_contains "apk add ran post-install" "$(cat "${WORKDIR}/out-signed.log")" "post-install"
else
    cat "${WORKDIR}/out-signed.log"
    log_fail "signed feed: install.sh's apk path FAILED -- this is the load-bearing assertion"
fi

# Re-run once more, standalone, purely to pull `tailscaled --version` out of
# the freshly-installed container and confirm it's the REAL binary (not a
# stub) -- separate container since apk add already mutated the previous
# one and it was torn down.
_cid=$(docker create --network host "${ROOTFS_IMAGE_TAG}" sh -c "sleep 600")
track "${_cid}"
docker start "${_cid}" >/dev/null
NATIVE_ARCH_LINE=$(docker exec "${_cid}" cat /etc/apk/arch)
docker exec "${_cid}" sh -c "printf '%s\n%s\n' '${NATIVE_ARCH_LINE}' '${ARCH}' > /etc/apk/arch"
docker exec "${_cid}" sh -c "rm -f /etc/apk/repositories.d/*.list"
docker exec "${_cid}" mkdir -p /opt/install-test
docker cp "${INSTALL_DIR}/install.sh" "${_cid}:/opt/install-test/install.sh"
docker cp "${INSTALL_DIR}/lib-install.sh" "${_cid}:/opt/install-test/lib-install.sh"
docker exec -e "APK_FEED_SCHEME=http" -e "APK_FEED_HOST=127.0.0.1:${PORT}" -e "AUTO_YES=true" \
    "${_cid}" sh /opt/install-test/install.sh -y >"${WORKDIR}/second-install.log" 2>&1 || {
    cat "${WORKDIR}/second-install.log"
    log_fail "second signed-feed install (for version check) failed"
}
if VERSION_OUT=$(docker exec "${_cid}" /usr/sbin/tailscaled --version 2>&1); then
    assert_contains "tailscaled --version reports the built version" "${VERSION_OUT}" "${TEST_VERSION}"
else
    log_fail "tailscaled --version failed to execute after install.sh's trusted install (${VERSION_OUT})"
fi
untrack_and_remove "${_cid}"

harness_finish "tests/apk/install-dispatch.sh"
