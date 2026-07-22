#!/bin/sh
# tests/apk/install.sh
#
# Slice A4/A5b test: real install-verification of the built .apk inside the
# pinned OpenWrt 25.12 rootfs container, for every CORE (tier=="core") arch
# in arches.json (RFC docs/rfc-apk-builds.md §5 "Install (integration)" + §6
# slices A4 + A5b). A4 proved the mechanism on aarch64 only; A5b generalizes
# the same mechanism to all four arches, in its own arch-native rootfs
# container under qemu.
#
# RFC docs/rfc-apk-arch-coverage.md §5.8 slice S1c: arches.json widened from
# 4 to 35 rows in S1b, 31 of which are gated inert (tier==
# "extended"/"infeasible", rootfs_url == null -- pinning is deferred to
# S7a). The no-arg path goes through the same tier=="core" gated view
# scripts/select-matrix.sh's non-PR branch returns, so it still exercises
# exactly the 4 real bootable arches, not the full widened table.
#
# Asserts, after `apk add`-ing the real built .apk into each arch's
# container:
#   - `tailscaled --version` executes -- the real arch-native Go binary
#     running under qemu-user, proving payload arch + installability, not a
#     stub.
#   - `/etc/config/tailscale` (the UCI config) is on-device.
#   - `/etc/init.d/tailscale` (the init script) is on-device.
#   - the `tailscale` rc.d enable symlink exists (service REGISTERED -- the
#     RFC's own bar; a `start` failure is tolerated, see below).
#
# Records and prints per-arch wall-clock (build + emulated install) at the
# end (RFC §5's emulation-cost estimate).
#
# --- Two empirical corrections to the RFC's own working assumptions ------
#
# (1) Arch override is NOT `apk add --arch <foreign>` (A0's assumption).
#     Verified empirically against a bare, dependency-free foreign-arch
#     package: `apk add --allow-untrusted --arch aarch64_cortex-a53 ./x.apk`
#     is STILL "uninstallable" -- apk-tools 3.0.2's solver treats `--arch`
#     as replacing the whole transaction's acceptable-arch set, which then
#     conflicts with the ~130 already-installed base packages tagged the
#     container's native arch. The actual mechanism is `/etc/apk/arch`,
#     which accepts MULTIPLE arches -- one per line. Listing both the
#     container's native arch (already in the file) and our build arch
#     makes both simultaneously acceptable, and a PLAIN `apk add` (no
#     --arch flag at all) then succeeds. Same mechanism, reused per arch.
#
# (2) The container has no local package cache, network access is not
#     relied on (forced off via `docker --network none` for determinism),
#     and `kmod-tun`/`ca-bundle`/`ip-full`/`conntrack` cannot resolve from a
#     repo. `ca-bundle` is already part of the container's base image and
#     needs nothing; the other three are not. No flag combination alone
#     (--force-broken-world, --force-missing-repositories, --force-non-repository,
#     any combination thereof) makes `apk add` actually install a package
#     with unsatisfiable deps -- `--force-broken-world` "succeeds" only by
#     silently DELETING the tailscale constraint from world (verified: exit
#     0, but the package is never unpacked). The minimal working mechanism
#     is a tiny local, unsigned, offline package repository (`apk mkpkg` +
#     `apk mkndx`, both already host-available from the A1 apk-tools stage)
#     providing empty stub packages named for the three missing deps, added
#     via `apk add -X <stubrepo>/packages.adb --force-missing-repositories`
#     (the latter needed only to tolerate the container's own preconfigured,
#     unreachable-offline distfeeds.list URLs, not our stub repo). This
#     lands the real payload and runs post-install for real -- it does not
#     touch the network and does not stub `tailscaled` itself.
#
#     **A5b per-arch subtlety:** the stub packages must be acceptable to
#     EACH arch's container, i.e. their `arch:` info tag must be one of the
#     arches listed in that container's (post-mutation) `/etc/apk/arch`.
#     Rather than researching whether apk 3.0.2's solver special-cases a
#     "noarch"/"all" arch value (unconfirmed, and A4's own corrections
#     above show this solver does NOT behave the way its docs/intuition
#     suggest), this reuses the ALREADY-EMPIRICALLY-PROVEN mechanism: tag
#     each arch's stub set with that SAME build arch string (e.g.
#     `arm_cortex-a7` stubs get `--info arch:arm_cortex-a7`), which is
#     unconditionally in that container's acceptable-arch list because it's
#     the exact value A4's correction (1) above already appends there for
#     the real package. Confirmed empirically for all four arches (see
#     handoff notes) -- no arch needed a fallback.
#
# --- procd-less service start -------------------------------------------
# This is a live install (IPKG_INSTROOT unset), so `tailscale.postinst`
# would try `/etc/init.d/tailscale enable && start` -- but only if
# tailscale.config.enabled=1, which is NOT the shipped default (it ships
# disabled). So this test explicitly runs `enable` itself (mirroring what an
# operator or a future install.sh would do) to exercise the registration
# path. `/etc/init.d/tailscale enable` needs `/var/lock` (procd's rc.common
# helper writes a lock file there) which does not exist in an unbooted
# rootfs image (`/var` -> `tmp`, populated normally by preinit at boot) --
# created here as minimal container prep, not a package/apk concern. `start`
# is then attempted and its failure is TOLERATED (no procd/ubus is running
# in this container) -- the RFC's own bar is "service registered", not
# "service running".
#
# Uses the shared tests/apk/lib.sh harness. Self-contained per arch: builds
# the .apk, imports+verifies the pinned rootfs (reusing rootfs.sh's cache
# dir), builds the local per-arch stub-dep repo, and cleans up all
# containers/images it creates.  Network use is limited to the (cached,
# checksum-verified) rootfs download; the install itself runs with
# `--network none`.
#
# RFC §5.6/S7a (D2): INSTALL_NATIVE_ONLY=1 drops the multi-arch
# `/etc/apk/arch` override above (correction 1) and instead ASSERTS the
# container's own, un-mutated native arch already equals ARCH -- the
# native-arch-only verify the `apk-native-verify` CI job (matrixed over
# select-matrix.sh --verify-families) uses. Default (unset/0): unchanged
# override behavior, for the existing ipk_arches-scoped multi-arch coverage
# (aarch64_cortex-a53/arm_cortex-a7 are not their own family's true native
# match -- see scripts/families.sh --with-ci's header comment -- so that
# coverage still needs the override to install at all).
#
# Usage:
#   sh tests/apk/install.sh              # all arches in arches.json
#   sh tests/apk/install.sh <arch_name>  # single arch only (CI per-arch
#                                         # matrix step, mirrors qemu.sh)
#   INSTALL_NATIVE_ONLY=1 sh tests/apk/install.sh <arch_name>
#                                         # native-arch-only verify, no override

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
PKG_DIR="${REPO_ROOT}/tailscale-package"
ARCHES_JSON="${REPO_ROOT}/arches.json"
SELECT_MATRIX="${REPO_ROOT}/scripts/select-matrix.sh"
CACHE_DIR="${ROOTFS_CACHE_DIR:-${SCRIPT_DIR}/.cache}"
ONLY_ARCH="${1:-}"

# shellcheck source=tests/apk/lib.sh
. "${SCRIPT_DIR}/lib.sh"

require_cmd jq
require_cmd docker

TEST_VERSION="${INSTALL_TEST_VERSION:-1.92.2}"
TEST_PKG_RELEASE="${INSTALL_TEST_PKG_RELEASE:-1}"
EXPECT_VERSION="${TEST_VERSION}-r${TEST_PKG_RELEASE}"

if [ ! -f "${PKG_DIR}/Dockerfile" ]; then
    echo "FAIL: ${PKG_DIR}/Dockerfile not found" >&2
    exit 1
fi
if [ ! -f "${ARCHES_JSON}" ]; then
    echo "FAIL: ${ARCHES_JSON} not found" >&2
    exit 1
fi
if [ ! -x "${SELECT_MATRIX}" ]; then
    echo "FAIL: ${SELECT_MATRIX} not found or not executable" >&2
    exit 1
fi

mkdir -p "${CACHE_DIR}"

WORKDIR=$(mktemp -d)
CLEANUP_CIDS=""

cleanup() {
    for c in ${CLEANUP_CIDS}; do
        docker rm -f "${c}" >/dev/null 2>&1 || true
    done
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT

track() {
    CLEANUP_CIDS="${CLEANUP_CIDS} $1"
}

untrack_and_remove() {
    docker rm -f "$1" >/dev/null 2>&1 || true
    CLEANUP_CIDS=$(echo "${CLEANUP_CIDS}" | sed "s/$1//")
}

# --- binfmt self-heal: standard arches (aarch64/armv7) + OpenWrt's custom
# ABIVERSION-wildcarded 32-bit mips/mipsel entries (A0/A5a finding -- stock
# registration rejects OpenWrt's EI_ABIVERSION=1 musl-softfloat ELFs).
# Registered together, lazily, on first exec failure -- one registration
# covers every arch for the rest of this run. ---
BINFMT_DONE=0
ensure_binfmt() {
    if [ "${BINFMT_DONE}" -eq 1 ]; then
        return 0
    fi
    BINFMT_DONE=1
    echo "Registering qemu-user binfmt emulators (standard + OpenWrt mips)..." >&2
    register_standard_qemu_binfmt \
        || echo "WARN: standard binfmt registration failed (continuing)" >&2
    register_openwrt_mips_binfmt \
        || echo "WARN: OpenWrt mips binfmt registration failed (continuing)" >&2
}

# exec_in_container cid cmd... -- runs `docker exec`, self-healing once on
# an "exec format error" (missing/broken qemu-user binfmt registration).
exec_in_container() {
    _cid="$1"
    shift
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

# --- wall-clock recording (RFC §5 emulation-cost estimate) -----------------
TIMING_SUMMARY=""

record_timing() {
    # record_timing arch build_secs install_secs
    TIMING_SUMMARY="${TIMING_SUMMARY}
$1 build=${2}s install=${3}s total=$(( $2 + $3 ))s"
}

# --- per-arch install-verify -------------------------------------------
install_verify_one() {
    ARCH="$1"
    URL=$(jq -r --arg n "${ARCH}" '.[] | select(.name==$n) | .rootfs_url' "${ARCHES_JSON}")
    PIN=$(jq -r --arg n "${ARCH}" '.[] | select(.name==$n) | .rootfs_sha256' "${ARCHES_JSON}")
    EXPECT_CONTAINER_ARCH=$(jq -r --arg n "${ARCH}" '.[] | select(.name==$n) | .container_arch' "${ARCHES_JSON}")
    # RFC docs/rfc-apk-arch-coverage.md §5.1/S2: the Dockerfile's `build`
    # stage no longer derives GOARCH from OPENWRT_ARCH's name (hard-fails
    # instead), so it must be passed explicitly per-arch.
    ARCH_GOARCH=$(jq -r --arg n "${ARCH}" '.[] | select(.name==$n) | .goarch // ""' "${ARCHES_JSON}")
    ARCH_GOARM=$(jq -r --arg n "${ARCH}" '.[] | select(.name==$n) | .goarm // ""' "${ARCHES_JSON}")
    ARCH_GOMIPS=$(jq -r --arg n "${ARCH}" '.[] | select(.name==$n) | .gomips // ""' "${ARCHES_JSON}")
    ARCH_GOMIPS64=$(jq -r --arg n "${ARCH}" '.[] | select(.name==$n) | .gomips64 // ""' "${ARCHES_JSON}")
    ARCH_GO386=$(jq -r --arg n "${ARCH}" '.[] | select(.name==$n) | .go386 // ""' "${ARCHES_JSON}")

    echo ""
    echo "############################################"
    echo "### ${ARCH}"
    echo "############################################"

    if [ -z "${URL}" ] || [ "${URL}" = "null" ]; then
        log_fail "arches.json: ${ARCH} missing rootfs_url"
        return 0
    fi

    ROOTFS_IMAGE_TAG="owrt2512-rootfs:${ARCH}"
    BUILD_IMAGE_TAG="tailscale-apk-install-build:${ARCH}"

    # --- 1. pinned rootfs: download (cached) + sha256-verify + docker import ---
    DEST="${CACHE_DIR}/$(basename "${URL}")"

    NEED_DOWNLOAD=1
    if [ -f "${DEST}" ] && [ "$(sha256sum "${DEST}" | awk '{print $1}')" = "${PIN}" ]; then
        NEED_DOWNLOAD=0
    fi
    if [ "${NEED_DOWNLOAD}" -eq 1 ]; then
        echo "Downloading ${URL}"
        curl -fsSL -o "${DEST}.part" "${URL}"
        mv "${DEST}.part" "${DEST}"
    fi
    ACTUAL=$(sha256sum "${DEST}" | awk '{print $1}')
    if [ "${ACTUAL}" != "${PIN}" ]; then
        log_fail "${ARCH}: rootfs sha256 mismatch for ${DEST} (expected ${PIN}, got ${ACTUAL})"
        return 0
    fi
    echo "rootfs sha256 OK (${ACTUAL})"

    docker import "${DEST}" "${ROOTFS_IMAGE_TAG}" >/dev/null
    echo "imported ${ROOTFS_IMAGE_TAG}"

    # --- 2. build the real .apk (RFC docs/rfc-apk-arch-coverage.md §5.1/S4:
    # `docker build --target apk` no longer exists -- compile the family
    # binary via `--target build` then package host-side via
    # scripts/package-apk.sh, both wrapped by tests/apk/lib.sh's
    # build_apk_host. BUILD_IMAGE_TAG is still tagged/available afterward
    # for the stub-dep repo step below, which needs a live container with
    # `apk` on PATH -- the `build` stage still COPYs it in.) --------------
    BUILD_START=$(date +%s)
    echo "Building family binary + packaging .apk (arch=${ARCH}, version=${EXPECT_VERSION})..."
    if ! build_apk_host "${PKG_DIR}" "${ARCH}" \
            "${ARCH_GOARCH}" "${ARCH_GOARM}" "${ARCH_GOMIPS}" "${ARCH_GOMIPS64}" "${ARCH_GO386}" \
            "${TEST_VERSION}" "${TEST_PKG_RELEASE}" \
            "${WORKDIR}/tailscale-${ARCH}.apk" "${BUILD_IMAGE_TAG}"; then
        log_fail "${ARCH}: build_apk_host (compile + package) failed"
        return 0
    fi
    if [ ! -s "${WORKDIR}/tailscale-${ARCH}.apk" ]; then
        log_fail "${ARCH}: .apk missing/empty after build_apk_host"
        return 0
    fi
    BUILD_END=$(date +%s)
    BUILD_SECS=$(( BUILD_END - BUILD_START ))
    echo "OK: built .apk extracted ($(du -h "${WORKDIR}/tailscale-${ARCH}.apk" | cut -f1)) in ${BUILD_SECS}s"

    INSTALL_START=$(date +%s)

    # --- 3. local per-arch stub-dep repo (correction 2 above): kmod-tun/
    # ip-full/conntrack are not resolvable offline; ca-bundle is already in
    # the base image. Tag each stub with THIS arch's build-arch string, so
    # it's acceptable in the same /etc/apk/arch mutation used for the real
    # package (empirically the safest choice -- see header note). ---------
    STUB_CID=$(docker create "${BUILD_IMAGE_TAG}" sh -c "sleep 600")
    track "${STUB_CID}"
    docker start "${STUB_CID}" >/dev/null
    docker exec "${STUB_CID}" mkdir -p /stubwork/empty /stubout
    for dep in kmod-tun ip-full conntrack; do
        docker exec "${STUB_CID}" sh -c \
            "apk mkpkg --allow-untrusted --info 'name:${dep}' --info 'version:1-r1' --info 'arch:${ARCH}' --files /stubwork/empty --output /stubout/${dep}-1-r1.apk"
    done
    docker exec "${STUB_CID}" sh -c "apk mkndx --allow-untrusted --output /stubout/packages.adb /stubout/*.apk"
    mkdir -p "${WORKDIR}/stubrepo-${ARCH}"
    docker cp "${STUB_CID}:/stubout/." "${WORKDIR}/stubrepo-${ARCH}/"
    untrack_and_remove "${STUB_CID}"
    echo "OK: local stub-dep repo built for ${ARCH} (kmod-tun, ip-full, conntrack)"

    # --- 4. target container: offline (--network none), long-lived for exec ---
    TARGET_CID=$(docker create --network none "${ROOTFS_IMAGE_TAG}" sh -c "sleep 600")
    track "${TARGET_CID}"
    docker start "${TARGET_CID}" >/dev/null

    if ! CONTAINER_ARCH=$(exec_in_container "${TARGET_CID}" apk --print-arch); then
        log_fail "${ARCH}: 'apk --print-arch' failed in target container (${CONTAINER_ARCH})"
        untrack_and_remove "${TARGET_CID}"
        return 0
    fi
    assert_eq "${ARCH}: container_arch matches arches.json pin" "${EXPECT_CONTAINER_ARCH}" "${CONTAINER_ARCH}"

    docker cp "${WORKDIR}/tailscale-${ARCH}.apk" "${TARGET_CID}:/tailscale.apk"
    docker exec "${TARGET_CID}" mkdir -p /stubrepo
    docker cp "${WORKDIR}/stubrepo-${ARCH}/." "${TARGET_CID}:/stubrepo/"

    # RFC §5.6/S7a D2: INSTALL_NATIVE_ONLY=1 drops the multi-arch override --
    # the whole point of the CI native-verify job is to exercise the
    # device's REAL, un-mutated /etc/apk/arch (the override is exactly what
    # hid the original arm_cortex-a7-vs-armsr/armv7 mismatch). Default
    # (unset): Correction 1's original behavior, unchanged -- appends ARCH
    # as an additional acceptable line via apk_arch_override_line
    # (tests/apk/lib.sh) -- kept for the existing ipk_arches-scoped
    # multi-arch install coverage, which genuinely needs it (aarch64_cortex-
    # a53/arm_cortex-a7 are NOT their own family's true native match --
    # see families.sh --with-ci's header comment).
    NATIVE_ARCH_LINE=$(docker exec "${TARGET_CID}" cat /etc/apk/arch)
    if [ "${INSTALL_NATIVE_ONLY:-0}" = "1" ]; then
        if ! native_arch_matches "${NATIVE_ARCH_LINE}" "${ARCH}"; then
            log_fail "${ARCH}: INSTALL_NATIVE_ONLY=1 but the container's native /etc/apk/arch ('$(printf '%s' "${NATIVE_ARCH_LINE}" | head -n1)') does not match -- this arch is NOT its rootfs's true native representative"
            untrack_and_remove "${TARGET_CID}"
            return 0
        fi
        log_info "OK: ${ARCH}: native /etc/apk/arch already matches -- no override applied (native-only verify)"
    else
        printf '%s\n' "$(apk_arch_override_line "${NATIVE_ARCH_LINE}" "${ARCH}")" \
            | docker exec -i "${TARGET_CID}" sh -c 'cat > /etc/apk/arch'
    fi
    echo "/etc/apk/arch now: $(docker exec "${TARGET_CID}" cat /etc/apk/arch | tr '\n' ' ')"

    # procd-less prep: /var -> tmp is empty in an unbooted rootfs; enable's
    # rc.common/procd.sh helper needs /var/lock to exist.
    docker exec "${TARGET_CID}" mkdir -p /var/lock /var/run

    # --- RED baseline (pre-install): the assertions below are meaningless if
    # they'd also pass against an empty container. Confirm the negative first. --
    if docker exec "${TARGET_CID}" test -e /usr/sbin/tailscaled 2>/dev/null; then
        log_fail "${ARCH}: RED baseline: tailscaled unexpectedly present before install"
    else
        log_info "OK: RED baseline: tailscaled absent before install (${ARCH})"
    fi
    if docker exec "${TARGET_CID}" test -e /etc/init.d/tailscale 2>/dev/null; then
        log_fail "${ARCH}: RED baseline: /etc/init.d/tailscale unexpectedly present before install"
    else
        log_info "OK: RED baseline: /etc/init.d/tailscale absent before install (${ARCH})"
    fi

    # --- 5. the real install ---------------------------------------------------
    # --allow-untrusted: no signed feed in this test (RFC: trust flows from a
    #   signed feed, out of scope here).
    # --force-missing-repositories: the container's preconfigured distfeeds.list
    #   URLs (downloads.openwrt.org) are unreachable under --network none;
    #   without this flag `add` refuses to proceed at all. It does NOT relax
    #   dependency resolution -- that's what the stub repo (-X) is for.
    # -X /stubrepo/packages.adb: this arch's local stub-dep repo built above.
    echo "=== apk add (${ARCH}) ==="
    if ! INSTALL_OUT=$(exec_in_container "${TARGET_CID}" \
            apk add --allow-untrusted --force-missing-repositories \
            -X /stubrepo/packages.adb /tailscale.apk); then
        echo "${INSTALL_OUT}"
        log_fail "${ARCH}: apk add failed"
        untrack_and_remove "${TARGET_CID}"
        return 0
    fi
    echo "${INSTALL_OUT}"
    assert_contains "${ARCH}: apk add ran post-install" "${INSTALL_OUT}" "Executing tailscale-${EXPECT_VERSION}.post-install"
    assert_contains "${ARCH}: apk add reported success" "${INSTALL_OUT}" "OK:"

    # --- 6. assertions -----------------------------------------------------
    # tailscaled --version: the real arch-native Go binary, executed under
    # qemu-user via the container's registered binfmt -- proves both "right
    # arch" and "actually runnable", not a stub.
    if ! VERSION_OUT=$(exec_in_container "${TARGET_CID}" /usr/sbin/tailscaled --version); then
        log_fail "${ARCH}: tailscaled --version failed to execute (${VERSION_OUT})"
    else
        echo "tailscaled --version (${ARCH}): ${VERSION_OUT}"
        assert_contains "${ARCH}: tailscaled --version reports built version" "${VERSION_OUT}" "${TEST_VERSION}"
    fi

    if docker exec "${TARGET_CID}" test -f /etc/config/tailscale; then
        log_info "OK: /etc/config/tailscale present (${ARCH})"
    else
        log_fail "${ARCH}: /etc/config/tailscale missing after install"
    fi

    if docker exec "${TARGET_CID}" test -x /etc/init.d/tailscale; then
        log_info "OK: /etc/init.d/tailscale present and executable (${ARCH})"
    else
        log_fail "${ARCH}: /etc/init.d/tailscale missing or not executable after install"
    fi

    # Service registration: explicitly enable (shipped default is disabled, so
    # post-install did not do this on its own) and assert the rc.d symlink,
    # tolerating a `start` failure (no procd/ubus running in this container --
    # the RFC's bar is "registered", not "running").
    ENABLE_OUT=$(exec_in_container "${TARGET_CID}" /etc/init.d/tailscale enable) || true
    echo "enable (${ARCH}): ${ENABLE_OUT}"

    RCD_OUT=$(docker exec "${TARGET_CID}" sh -c 'ls /etc/rc.d/ 2>/dev/null' || true)
    assert_contains "${ARCH}: rc.d enable symlink present (service registered)" "${RCD_OUT}" "tailscale"

    START_OUT=$(exec_in_container "${TARGET_CID}" /etc/init.d/tailscale start) || true
    echo "start (${ARCH}, best-effort, failure tolerated): ${START_OUT}"

    untrack_and_remove "${TARGET_CID}"

    INSTALL_END=$(date +%s)
    INSTALL_SECS=$(( INSTALL_END - INSTALL_START ))
    record_timing "${ARCH}" "${BUILD_SECS}" "${INSTALL_SECS}"
    echo "TIMING ${ARCH}: build=${BUILD_SECS}s install(qemu)=${INSTALL_SECS}s total=$(( BUILD_SECS + INSTALL_SECS ))s"
}

if [ -n "${ONLY_ARCH}" ]; then
    NAMES="${ONLY_ARCH}"
else
    # tier=="core" (RFC docs/rfc-apk-arch-coverage.md §5.8, slice S1c):
    # arches.json widened to 35 rows in S1b, 31 of which are gated inert
    # (tier=="extended"/"infeasible", rootfs_url == null -- pinning is
    # deferred to S7a). A bare `.[].name` here would run install_verify_one
    # against all 35 and spuriously log_fail on every gated-inert row.
    # Go through the same tier=="core" gated view select-matrix.sh's
    # non-PR branch returns, so this exercises exactly the 4 real bootable
    # core arches, same as before the widen.
    NAMES=$("${SELECT_MATRIX}" workflow_dispatch "${ARCHES_JSON}" | jq -r '.[].name')
fi

for _arch in ${NAMES}; do
    install_verify_one "${_arch}"
done

echo ""
echo "############################################"
echo "### wall-clock summary (build + emulated install)"
echo "############################################"
echo "${TIMING_SUMMARY}"

harness_finish "tests/apk/install.sh"
