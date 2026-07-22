#!/bin/sh
# tests/apk/compile-negative.sh
#
# Slice S2 negative test (RFC docs/rfc-apk-arch-coverage.md §5.1/S2): the
# Dockerfile `build` stage used to derive GOARCH by a string-`case` on
# OPENWRT_ARCH with a `*) -> mips` default -- an unrecognized/new arch name
# silently built a 32-bit MIPS binary instead of failing. Confirmed
# empirically before this refactor (see the S2 handoff report): building
# `--target build` for a bogus arch name against the PRE-refactor Dockerfile
# (git HEAD, since S1 never touched the build stage) produced a real,
# non-empty ELF32 big-endian "MIPS R3000" /build/tailscaled with NO error at
# all -- the exact silent-mis-build bug this slice deletes.
#
# This script asserts the POST-refactor Dockerfile instead HARD-FAILS
# (`docker build` exits non-zero, with a clear diagnostic on stderr/log)
# whenever:
#   (a) GOARCH is left empty (not passed as a --build-arg at all);
#   (b) GOARCH is passed but is not one of Go's known GOARCH values;
#   (c) GOARCH=mips/mipsle but GOMIPS is left empty (Go's silent hardfloat
#       default SIGILLs on softfloat MIPS silicon -- the same class of live
#       bug already fixed once for arm_cortex-a7, see RFC §9);
#   (d) GOARCH=mips64/mips64le but GOMIPS64 is left empty (same reasoning);
#   (e) GOARCH=arm but GOARM is left empty (L7 code-review finding: every
#       arm row in arches.json requires a specific GOARM, same class of
#       silently-wrong-build risk as (c)/(d), even though Go's own default
#       doesn't SIGILL here);
#   (f) GOARCH=386 but GO386 is left empty (L7, same reasoning as (e) for
#       the 386 float ABI).
# ...and a POSITIVE control that a fully-specified, valid tuple still
# succeeds (the validation must not reject legitimate input).
#
# Cheap: each negative case fails at the validation RUN layer, which sits
# AFTER the (docker-cached, arch-independent) zypper-install/tailscale-source
# layers, so only the first invocation in a fresh environment pays that cost.
#
# Usage: sh tests/apk/compile-negative.sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
PKG_DIR="${REPO_ROOT}/tailscale-package"

# shellcheck source=tests/apk/lib.sh
. "${SCRIPT_DIR}/lib.sh"

require_cmd docker

if [ ! -f "${PKG_DIR}/Dockerfile" ]; then
    echo "FAIL: ${PKG_DIR}/Dockerfile not found" >&2
    exit 1
fi

TEST_VERSION="${COMPILE_NEGATIVE_TEST_VERSION:-1.92.2}"
TEST_PKG_RELEASE="${COMPILE_NEGATIVE_TEST_PKG_RELEASE:-1}"

WORKDIR=$(mktemp -d)
trap 'rm -rf "${WORKDIR}"' EXIT

# assert_build_fails desc openwrt_arch goarch goarm gomips gomips64 go386 [expect_grep]
assert_build_fails() {
    _desc="$1"; _arch="$2"; _goarch="$3"; _goarm="$4"; _gomips="$5"; _gomips64="$6"; _go386="$7"
    _expect_grep="${8:-}"
    _log="${WORKDIR}/$(echo "${_desc}" | tr -c 'a-zA-Z0-9' '_').log"
    _tag="tailscale-compile-negative-$$:test"

    if docker build \
        --progress=plain \
        --target build \
        --build-arg TAILSCALE_VERSION="${TEST_VERSION}" \
        --build-arg PKG_RELEASE="${TEST_PKG_RELEASE}" \
        --build-arg OPENWRT_ARCH="${_arch}" \
        --build-arg GOARCH="${_goarch}" \
        --build-arg GOARM="${_goarm}" \
        --build-arg GOMIPS="${_gomips}" \
        --build-arg GOMIPS64="${_gomips64}" \
        --build-arg GO386="${_go386}" \
        --build-arg SKIP_UPX=1 \
        -t "${_tag}" \
        -f "${PKG_DIR}/Dockerfile" "${PKG_DIR}" >"${_log}" 2>&1; then
        log_fail "${_desc}: docker build unexpectedly SUCCEEDED (should have hard-failed) -- see ${_log}"
        docker rmi "${_tag}" >/dev/null 2>&1 || true
        return
    fi

    log_info "OK: ${_desc}: docker build failed as expected"

    if [ -n "${_expect_grep}" ]; then
        if grep -q "${_expect_grep}" "${_log}"; then
            log_info "OK: ${_desc}: failure log mentions '${_expect_grep}'"
        else
            log_fail "${_desc}: failure log does NOT mention '${_expect_grep}' -- see ${_log}"
        fi
    fi

    docker rmi "${_tag}" >/dev/null 2>&1 || true
}

echo "=== negative: GOARCH left empty (no --build-arg GOARCH at all) hard-fails ==="
assert_build_fails "empty GOARCH" "totally_bogus_arch_xyz" "" "" "" "" "" \
    "GOARCH='' is empty or not a recognized Go GOARCH"

echo
echo "=== negative: unrecognized GOARCH value hard-fails ==="
assert_build_fails "bogus GOARCH value" "totally_bogus_arch_xyz" "bogus123" "" "" "" "" \
    "GOARCH='bogus123' is empty or not a recognized Go GOARCH"

echo
echo "=== negative: GOARCH=mips with empty GOMIPS hard-fails (MIPS SIGILL safety guard) ==="
assert_build_fails "mips with empty GOMIPS" "mips_24kc" "mips" "" "" "" "" \
    "GOARCH=mips requires GOMIPS to be set explicitly"

echo
echo "=== negative: GOARCH=mipsle with empty GOMIPS hard-fails ==="
assert_build_fails "mipsle with empty GOMIPS" "mipsel_24kc" "mipsle" "" "" "" "" \
    "GOARCH=mipsle requires GOMIPS to be set explicitly"

echo
echo "=== negative: GOARCH=mips64 with empty GOMIPS64 hard-fails (MIPS64 SIGILL safety guard) ==="
assert_build_fails "mips64 with empty GOMIPS64" "mips64_mips64r2" "mips64" "" "" "" "" \
    "GOARCH=mips64 requires GOMIPS64 to be set explicitly"

echo
echo "=== negative: GOARCH=mips64le with empty GOMIPS64 hard-fails ==="
assert_build_fails "mips64le with empty GOMIPS64" "mips64el_mips64r2" "mips64le" "" "" "" "" \
    "GOARCH=mips64le requires GOMIPS64 to be set explicitly"

echo
echo "=== negative (L7): GOARCH=arm with empty GOARM hard-fails ==="
assert_build_fails "arm with empty GOARM" "arm_cortex-a9" "arm" "" "" "" "" \
    "GOARCH=arm requires GOARM to be set explicitly"

echo
echo "=== negative (L7): GOARCH=386 with empty GO386 hard-fails ==="
assert_build_fails "386 with empty GO386" "i386_pentium4" "386" "" "" "" "" \
    "GOARCH=386 requires GO386 to be set explicitly"

echo
echo "=== positive control: a fully-specified valid tuple still succeeds ==="
POS_TAG="tailscale-compile-negative-positive:test"
POS_LOG="${WORKDIR}/positive.log"
if docker build \
    --progress=plain \
    --target build \
    --build-arg TAILSCALE_VERSION="${TEST_VERSION}" \
    --build-arg PKG_RELEASE="${TEST_PKG_RELEASE}" \
    --build-arg OPENWRT_ARCH=aarch64_cortex-a53 \
    --build-arg GOARCH=arm64 \
    --build-arg SKIP_UPX=1 \
    -t "${POS_TAG}" \
    -f "${PKG_DIR}/Dockerfile" "${PKG_DIR}" >"${POS_LOG}" 2>&1; then
    log_info "OK: valid arm64 tuple builds successfully (validation does not reject legitimate input)"
else
    log_fail "valid arm64 tuple unexpectedly failed to build -- see ${POS_LOG}"
fi
docker rmi "${POS_TAG}" >/dev/null 2>&1 || true

# Also positively confirm a valid mips tuple (GOMIPS set) succeeds -- the
# mirror image of the "mips with empty GOMIPS" negative case above.
echo
echo "=== positive control: mips_24kc with GOMIPS=softfloat set still succeeds ==="
POS_MIPS_TAG="tailscale-compile-negative-positive-mips:test"
POS_MIPS_LOG="${WORKDIR}/positive-mips.log"
if docker build \
    --progress=plain \
    --target build \
    --build-arg TAILSCALE_VERSION="${TEST_VERSION}" \
    --build-arg PKG_RELEASE="${TEST_PKG_RELEASE}" \
    --build-arg OPENWRT_ARCH=mips_24kc \
    --build-arg GOARCH=mips \
    --build-arg GOMIPS=softfloat \
    --build-arg SKIP_UPX=1 \
    -t "${POS_MIPS_TAG}" \
    -f "${PKG_DIR}/Dockerfile" "${PKG_DIR}" >"${POS_MIPS_LOG}" 2>&1; then
    log_info "OK: valid mips_24kc tuple (GOMIPS=softfloat) builds successfully"
else
    log_fail "valid mips_24kc tuple unexpectedly failed to build -- see ${POS_MIPS_LOG}"
fi
docker rmi "${POS_MIPS_TAG}" >/dev/null 2>&1 || true

# Also positively confirm a valid arm tuple (GOARM set) succeeds -- the
# mirror image of the "arm with empty GOARM" (L7) negative case above.
echo
echo "=== positive control (L7): arm_cortex-a9 with GOARM=5 set still succeeds ==="
POS_ARM_TAG="tailscale-compile-negative-positive-arm:test"
POS_ARM_LOG="${WORKDIR}/positive-arm.log"
if docker build \
    --progress=plain \
    --target build \
    --build-arg TAILSCALE_VERSION="${TEST_VERSION}" \
    --build-arg PKG_RELEASE="${TEST_PKG_RELEASE}" \
    --build-arg OPENWRT_ARCH=arm_cortex-a9 \
    --build-arg GOARCH=arm \
    --build-arg GOARM=5 \
    --build-arg SKIP_UPX=1 \
    -t "${POS_ARM_TAG}" \
    -f "${PKG_DIR}/Dockerfile" "${PKG_DIR}" >"${POS_ARM_LOG}" 2>&1; then
    log_info "OK: valid arm_cortex-a9 tuple (GOARM=5) builds successfully"
else
    log_fail "valid arm_cortex-a9 tuple unexpectedly failed to build -- see ${POS_ARM_LOG}"
fi
docker rmi "${POS_ARM_TAG}" >/dev/null 2>&1 || true

# Also positively confirm a valid 386 tuple (GO386 set) succeeds -- the
# mirror image of the "386 with empty GO386" (L7) negative case above.
echo
echo "=== positive control (L7): i386_pentium4 with GO386=sse2 set still succeeds ==="
POS_386_TAG="tailscale-compile-negative-positive-386:test"
POS_386_LOG="${WORKDIR}/positive-386.log"
if docker build \
    --progress=plain \
    --target build \
    --build-arg TAILSCALE_VERSION="${TEST_VERSION}" \
    --build-arg PKG_RELEASE="${TEST_PKG_RELEASE}" \
    --build-arg OPENWRT_ARCH=i386_pentium4 \
    --build-arg GOARCH=386 \
    --build-arg GO386=sse2 \
    --build-arg SKIP_UPX=1 \
    -t "${POS_386_TAG}" \
    -f "${PKG_DIR}/Dockerfile" "${PKG_DIR}" >"${POS_386_LOG}" 2>&1; then
    log_info "OK: valid i386_pentium4 tuple (GO386=sse2) builds successfully"
else
    log_fail "valid i386_pentium4 tuple unexpectedly failed to build -- see ${POS_386_LOG}"
fi
docker rmi "${POS_386_TAG}" >/dev/null 2>&1 || true

harness_finish "tests/apk/compile-negative.sh"
