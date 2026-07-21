#!/bin/sh
# tests/apk/release-checksums.sh
#
# Slice C4 test (RFC docs/rfc-apk-builds.md §4.3, §6 slice C4): the
# `release` workflow job's inline `sha256sum *.ipk tailscaled_*` step is
# factored out into scripts/release-checksums.sh so "does SHA256SUMS list
# every expected release asset with a correct hash" is locally runnable
# over a directory of `.ipk` + `.apk` + `.pem` files, without a live
# release. Asserts all of:
#
#   1. every expected asset (4 .ipk, 4 .apk, 1 pubkey .pem -- 9 total, the
#      RFC's own C4 test bullet) appears as a line in the generated
#      SHA256SUMS.
#   2. the generated SHA256SUMS is itself correct: `sha256sum -c` against
#      it, run from inside the assets dir, verifies clean.
#   3. re-running the script against a dir that ALREADY has a SHA256SUMS in
#      it (the upsert/second-gh-release-call scenario, §4.3) does not fold
#      SHA256SUMS's own hash into itself.
#
# Uses the shared tests/apk/lib.sh harness (established slice A2).
#
# Usage: sh tests/apk/release-checksums.sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
CHECKSUMS_SCRIPT="${REPO_ROOT}/scripts/release-checksums.sh"

# shellcheck source=tests/apk/lib.sh
. "${SCRIPT_DIR}/lib.sh"

require_cmd sha256sum

WORKDIR=$(mktemp -d)
trap 'rm -rf "${WORKDIR}"' EXIT

# --- fixture: a representative combined release-assets dir --------------
# 4 arches x (1 .ipk + 1 raw tailscaled_* binary + 1 arch-namespaced .apk)
# + 1 pubkey .pem -- matches what release-apk-assets assembles in the real
# workflow (arch-namespaced .apk filenames, per the C1b collision finding).
ARCHES="aarch64_cortex-a53 arm_cortex-a7 mips_24kc mipsel_24kc"
VERSION="1.92.2"
PKG_RELEASE="r1"

for arch in ${ARCHES}; do
    echo "fake ipk payload for ${arch}" > "${WORKDIR}/tailscale_${VERSION}_${arch}.ipk"
    echo "fake raw binary for ${arch}" > "${WORKDIR}/tailscaled_${VERSION}_${arch}"
    echo "fake apk payload for ${arch}" > "${WORKDIR}/tailscale-${VERSION}-${PKG_RELEASE}-${arch}.apk"
done
echo "fake EC public key" > "${WORKDIR}/apk-signing.pem"

# --- 1. script must exist --------------------------------------------------

if [ ! -x "${CHECKSUMS_SCRIPT}" ]; then
    log_fail "scripts/release-checksums.sh not found or not executable at ${CHECKSUMS_SCRIPT}"
    harness_finish "tests/apk/release-checksums.sh"
    exit "${FAIL}"
fi

# --- 2. generate + assert every expected asset is listed ------------------

echo "=== generate SHA256SUMS over combined ipk+apk+pubkey dir ==="

"${CHECKSUMS_SCRIPT}" "${WORKDIR}"

if [ ! -f "${WORKDIR}/SHA256SUMS" ]; then
    log_fail "SHA256SUMS was not generated at ${WORKDIR}/SHA256SUMS"
else
    SUMS_CONTENT=$(cat "${WORKDIR}/SHA256SUMS")
    LINE_COUNT=$(wc -l < "${WORKDIR}/SHA256SUMS" | tr -d ' ')

    # 4 ipk + 4 raw tailscaled_* + 4 apk + 1 pubkey = 13 lines. The RFC's
    # C4 test bullet calls out "4 ipk + 4 apk + pubkey appear" as the
    # load-bearing minimum -- the raw tailscaled_* binaries are additional,
    # pre-existing (ipk-side) entries this script must keep covering too
    # (byte-unchanged ipk behavior, §4.3 discipline).
    assert_eq "SHA256SUMS has one line per asset (4 ipk + 4 raw + 4 apk + 1 pubkey)" "13" "${LINE_COUNT}"

    for arch in ${ARCHES}; do
        assert_contains "SHA256SUMS lists tailscale_${VERSION}_${arch}.ipk" "${SUMS_CONTENT}" "tailscale_${VERSION}_${arch}.ipk"
        assert_contains "SHA256SUMS lists tailscaled_${VERSION}_${arch}" "${SUMS_CONTENT}" "tailscaled_${VERSION}_${arch}"
        assert_contains "SHA256SUMS lists tailscale-${VERSION}-${PKG_RELEASE}-${arch}.apk (arch-namespaced)" "${SUMS_CONTENT}" "tailscale-${VERSION}-${PKG_RELEASE}-${arch}.apk"
    done
    assert_contains "SHA256SUMS lists apk-signing.pem" "${SUMS_CONTENT}" "apk-signing.pem"

    # --- 3. correctness: the generated file must actually verify ----------
    if (cd "${WORKDIR}" && sha256sum -c SHA256SUMS >"${WORKDIR}/.verify.log" 2>&1); then
        log_info "OK: sha256sum -c SHA256SUMS verifies every listed asset"
    else
        log_fail "sha256sum -c SHA256SUMS failed:
$(cat "${WORKDIR}/.verify.log")"
    fi
fi

echo

# --- 4. re-run (upsert scenario): must not checksum SHA256SUMS itself -----

echo "=== re-run against a dir that already has a SHA256SUMS (upsert scenario) ==="

"${CHECKSUMS_SCRIPT}" "${WORKDIR}"
RERUN_CONTENT=$(cat "${WORKDIR}/SHA256SUMS")
RERUN_LINES=$(wc -l < "${WORKDIR}/SHA256SUMS" | tr -d ' ')

assert_eq "line count unchanged after re-run (SHA256SUMS did not fold itself in)" "13" "${RERUN_LINES}"
assert_not_contains "SHA256SUMS does not list its own filename" "${RERUN_CONTENT}" " SHA256SUMS"

harness_finish "tests/apk/release-checksums.sh"
