#!/bin/sh
# tests/apk/qemu.sh
#
# Slice A5a/S7a test (RFC docs/rfc-apk-builds.md §6; RFC
# docs/rfc-apk-arch-coverage.md §5.6): proves the CI qemu binfmt setup --
# `docker/setup-qemu-action` PLUS the custom ABIVERSION-wildcarded 32-bit
# mips/mipsel binfmt_misc entries (root-caused in A0; reference
# implementation in tests/apk/rootfs.sh, factored into lib.sh's
# register_standard_qemu_binfmt/register_openwrt_mips_binfmt for reuse here) --
# actually lets a foreign-arch container exec. Two things are asserted:
#
#   1. Binfmt + exec: S7a widens this from the 4 tier=="core" arches to
#      scripts/select-matrix.sh --verify-families' 10 CI-bootable family
#      representatives (RFC §5.6) -- for each (or just one, if given as $1 --
#      this is how the CI matrix job invokes it per-arch), `docker run` the
#      pinned rootfs image and assert a trivial foreign binary execs
#      (`uname -m`) and reports the expected machine. Binfmt registration is
#      UNCONDITIONAL and reset-first here (unlike rootfs.sh's lazy self-heal
#      on failure) so this test is a real proof of registration, not reliant
#      on host state left over from a previous run.
#
#      This exec check goes through --verify-families (not the raw 35-row
#      table, and not `.[].name` -- verify_families rows carry `.verify` as
#      the arch NAME field) so it never attempts to download/import a `null`
#      rootfs for one of the 25 non-representative or 4 S7b-unverified rows.
#
#   2. Matrix-selection logic (§5 "CI cost / emulation policy"): asserts
#      scripts/select-matrix.sh selects the canary arch (mips_24kc) for a
#      simulated `pull_request` event and the tier=="core" 4-arch set for
#      any other event (e.g. `workflow_dispatch`) -- without a live GitHub
#      Actions run. (This still exercises the DEFAULT/--ipk-arches mode,
#      unaffected by --verify-families -- see tests/apk/select-matrix.sh for
#      the --verify-families-specific selection assertions.)
#
# Reuses rootfs.sh's cache dir (tests/apk/.cache) so a prior rootfs.sh run's
# downloaded/verified tarballs aren't re-fetched; imports with the same
# `owrt2512-rootfs:<name>` tag convention so either script can reuse the
# other's cached image.
#
# Usage:
#   sh tests/apk/qemu.sh              # all 10 verify_families arches + matrix-logic assertion
#   sh tests/apk/qemu.sh <arch_name>  # single arch only (CI per-arch matrix step)

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
ARCHES_JSON="${REPO_ROOT}/arches.json"
SELECT_MATRIX="${REPO_ROOT}/scripts/select-matrix.sh"
CACHE_DIR="${ROOTFS_CACHE_DIR:-${SCRIPT_DIR}/.cache}"
ONLY_ARCH="${1:-}"

# shellcheck source=tests/apk/lib.sh
. "${SCRIPT_DIR}/lib.sh"

require_cmd jq
require_cmd docker

if [ ! -f "${ARCHES_JSON}" ]; then
    echo "FAIL: ${ARCHES_JSON} not found" >&2
    exit 1
fi
if [ ! -x "${SELECT_MATRIX}" ]; then
    echo "FAIL: ${SELECT_MATRIX} not found or not executable" >&2
    exit 1
fi

mkdir -p "${CACHE_DIR}"

# --- 1. binfmt registration (unconditional, reset-first) -------------------

echo "=== binfmt registration ==="
if [ "${QEMU_SKIP_BINFMT_SETUP:-0}" = "1" ]; then
    echo "QEMU_SKIP_BINFMT_SETUP=1: not attempting binfmt setup" >&2
else
    echo "Registering standard qemu-user binfmt emulators..." >&2
    if ! register_standard_qemu_binfmt; then
        log_fail "register_standard_qemu_binfmt failed"
    fi
    echo "Registering OpenWrt 32-bit mips/mipsel binfmt entries (ABIVERSION-wildcarded)..." >&2
    if ! register_openwrt_mips_binfmt; then
        log_fail "register_openwrt_mips_binfmt failed"
    fi
    # S7a M3 spike: multiarch/qemu-user-static (above) ships no loong64
    # emulator at all -- local-dev-only supplement, see lib.sh's own
    # comment. The real CI qemu-verify job sets QEMU_SKIP_BINFMT_SETUP=1
    # and relies on docker/setup-qemu-action@v3 (tonistiigi/binfmt) instead,
    # which already covers loong64.
    echo "Registering loongarch64 binfmt entry (tonistiigi/binfmt, local-dev supplement)..." >&2
    if ! register_loongarch64_binfmt; then
        log_fail "register_loongarch64_binfmt failed"
    fi
fi
echo

# --- 2. per-arch import + exec check ----------------------------------------
# uname -m under qemu-user reports the *emulated* machine (qemu patches the
# uname() syscall), which is exactly why this is a meaningful proof that
# binfmt registration -- not just qemu's ISA support -- is correct. Expected
# values are Linux's own uname(2) machine strings, not apk's `--print-arch`
# vocabulary (A0 already found those differ): mips 32-bit does not encode
# endianness in `uname -m` -- both mips_24kc (BE) and mipsel_24kc (LE) report
# "mips". This is not a test bug; it matches real OpenWrt mips/mipsel devices.
#
# S7a: extended for the --verify-families set (RFC §5.6's 10 bootable
# families, up from the 4 tier==core arches this covered before). Three of
# these (i386_pentium4/i386_pentium-mmx/x86_64) run NATIVELY on an x86_64
# runner -- no qemu involved at all -- and empirically report the HOST
# kernel's own machine string (x86_64), not a 32-bit-specific one; that is
# not a test bug either, it is how 32-bit x86 userland runs on an x86_64
# kernel (verified empirically, S7a handoff notes).
expected_uname_m() {
    case "$1" in
        aarch64_cortex-a53) echo "aarch64" ;;
        arm_cortex-a7) echo "armv7l" ;;
        mips_24kc) echo "mips" ;;
        mipsel_24kc) echo "mips" ;;
        aarch64_generic) echo "aarch64" ;;
        arm_cortex-a15_neon-vfpv4) echo "armv7l" ;;
        mips64_mips64r2) echo "mips64" ;;
        mips64el_mips64r2) echo "mips64" ;;
        i386_pentium4) echo "x86_64" ;;
        i386_pentium-mmx) echo "x86_64" ;;
        x86_64) echo "x86_64" ;;
        loongarch64_generic) echo "loongarch64" ;;
        *) echo "" ;;
    esac
}

echo "=== per-arch exec check ==="
# S7a: --verify-families (the 10 CI-bootable family representatives),
# event-conditionally the same way every other select-matrix mode is --
# not the raw 35-row table, and no longer just the 4 tier==core arches
# (RFC §5.6's widened CI-verify scope). Rows carry `.verify` as the arch
# NAME field (arches.sh --with-ci's own naming), not `.name`.
VERIFY_ARCHES=$("${SELECT_MATRIX}" workflow_dispatch --verify-families "${ARCHES_JSON}")
COUNT=$(echo "${VERIFY_ARCHES}" | jq 'length')
i=0
while [ "$i" -lt "$COUNT" ]; do
    NAME=$(echo "${VERIFY_ARCHES}" | jq -r ".[$i].verify")
    URL=$(echo "${VERIFY_ARCHES}" | jq -r ".[$i].rootfs_url")
    PIN=$(echo "${VERIFY_ARCHES}" | jq -r ".[$i].rootfs_sha256")
    i=$((i + 1))

    if [ -n "${ONLY_ARCH}" ] && [ "${NAME}" != "${ONLY_ARCH}" ]; then
        continue
    fi

    echo "--- ${NAME} ---"

    DEST="${CACHE_DIR}/$(basename "${URL}")"
    NEED_DOWNLOAD=1
    if [ -f "${DEST}" ]; then
        ACTUAL=$(sha256sum "${DEST}" | awk '{print $1}')
        [ "${ACTUAL}" = "${PIN}" ] && NEED_DOWNLOAD=0
    fi
    if [ "${NEED_DOWNLOAD}" -eq 1 ]; then
        echo "Downloading ${URL}"
        if ! curl -fsSL -o "${DEST}.part" "${URL}"; then
            log_fail "${NAME}: download failed for ${URL}"
            continue
        fi
        mv "${DEST}.part" "${DEST}"
    fi
    ACTUAL=$(sha256sum "${DEST}" | awk '{print $1}')
    if [ "${ACTUAL}" != "${PIN}" ]; then
        log_fail "${NAME}: sha256 mismatch (expected ${PIN}, got ${ACTUAL})"
        continue
    fi

    IMAGE_TAG="owrt2512-rootfs:${NAME}"
    if ! docker import "${DEST}" "${IMAGE_TAG}" >/dev/null; then
        log_fail "${NAME}: docker import failed"
        continue
    fi

    if ! ACTUAL_UNAME=$(docker run --rm "${IMAGE_TAG}" uname -m 2>&1); then
        log_fail "${NAME}: 'uname -m' failed to exec in container (${ACTUAL_UNAME})"
        continue
    fi
    assert_eq "${NAME}: uname -m" "$(expected_uname_m "${NAME}")" "${ACTUAL_UNAME}"
done
echo

# --- 3. matrix-selection logic assertion ------------------------------------

echo "=== matrix-selection logic ==="

# RFC §5.8 S1c: PR selection keys strictly on canary==true (mips_24kc only
# -- the deleted `.canary == true or .container_arch == "aarch64"` OR-clause
# used to also pull in aarch64_cortex-a53); non-PR selection is gated to the
# tier=="core" 4-arch set, not the full (now 35-row) table.
PR_NAMES=$("${SELECT_MATRIX}" pull_request "${ARCHES_JSON}" | jq -c '[.[].name] | sort')
assert_eq "pull_request matrix" '["mips_24kc"]' "${PR_NAMES}"

CORE_NAMES='["aarch64_cortex-a53","arm_cortex-a7","mips_24kc","mipsel_24kc"]'

DISPATCH_NAMES=$("${SELECT_MATRIX}" workflow_dispatch "${ARCHES_JSON}" | jq -c '[.[].name] | sort')
assert_eq "workflow_dispatch matrix is the tier==core set (not the full 35-row table)" "${CORE_NAMES}" "${DISPATCH_NAMES}"

RELEASE_NAMES=$("${SELECT_MATRIX}" release "${ARCHES_JSON}" | jq -c '[.[].name] | sort')
assert_eq "release matrix is the tier==core set (not the full 35-row table)" "${CORE_NAMES}" "${RELEASE_NAMES}"

harness_finish "tests/apk/qemu.sh"
