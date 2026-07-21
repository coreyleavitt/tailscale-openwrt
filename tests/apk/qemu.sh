#!/bin/sh
# tests/apk/qemu.sh
#
# Slice A5a test (RFC docs/rfc-apk-builds.md §6): proves the CI qemu binfmt
# setup -- `docker/setup-qemu-action` PLUS the custom ABIVERSION-wildcarded
# 32-bit mips/mipsel binfmt_misc entries (root-caused in A0; reference
# implementation in tests/apk/rootfs.sh, factored into lib.sh's
# register_standard_qemu_binfmt/register_openwrt_mips_binfmt for reuse here) --
# actually lets a foreign-arch container exec. Two things are asserted:
#
#   1. Binfmt + exec: for each of the 4 arches.json entries (or just one, if
#      given as $1 -- this is how the CI matrix job invokes it per-arch),
#      `docker run` the pinned rootfs image and assert a trivial foreign
#      binary execs (`uname -m`) and reports the expected machine. Binfmt
#      registration is UNCONDITIONAL and reset-first here (unlike rootfs.sh's
#      lazy self-heal on failure) so this test is a real proof of
#      registration, not reliant on host state left over from a previous run.
#
#   2. Matrix-selection logic (§5 "CI cost / emulation policy"): asserts
#      scripts/select-matrix.sh selects {aarch64 arch, MIPS canary} for a
#      simulated `pull_request` event and the full 4-arch set for any other
#      event (e.g. `workflow_dispatch`) -- without a live GitHub Actions run.
#
# Reuses rootfs.sh's cache dir (tests/apk/.cache) so a prior rootfs.sh run's
# downloaded/verified tarballs aren't re-fetched; imports with the same
# `owrt2512-rootfs:<name>` tag convention so either script can reuse the
# other's cached image.
#
# Usage:
#   sh tests/apk/qemu.sh              # all 4 arches + matrix-logic assertion
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
expected_uname_m() {
    case "$1" in
        aarch64_cortex-a53) echo "aarch64" ;;
        arm_cortex-a7) echo "armv7l" ;;
        mips_24kc) echo "mips" ;;
        mipsel_24kc) echo "mips" ;;
        *) echo "" ;;
    esac
}

echo "=== per-arch exec check ==="
COUNT=$(jq 'length' "${ARCHES_JSON}")
i=0
while [ "$i" -lt "$COUNT" ]; do
    NAME=$(jq -r ".[$i].name" "${ARCHES_JSON}")
    URL=$(jq -r ".[$i].rootfs_url" "${ARCHES_JSON}")
    PIN=$(jq -r ".[$i].rootfs_sha256" "${ARCHES_JSON}")
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

PR_NAMES=$("${SELECT_MATRIX}" pull_request "${ARCHES_JSON}" | jq -c '[.[].name] | sort')
assert_eq "pull_request matrix" '["aarch64_cortex-a53","mips_24kc"]' "${PR_NAMES}"

FULL_NAMES=$(jq -c '[.[].name] | sort' "${ARCHES_JSON}")

DISPATCH_NAMES=$("${SELECT_MATRIX}" workflow_dispatch "${ARCHES_JSON}" | jq -c '[.[].name] | sort')
assert_eq "workflow_dispatch matrix" "${FULL_NAMES}" "${DISPATCH_NAMES}"

RELEASE_NAMES=$("${SELECT_MATRIX}" release "${ARCHES_JSON}" | jq -c '[.[].name] | sort')
assert_eq "release matrix" "${FULL_NAMES}" "${RELEASE_NAMES}"

harness_finish "tests/apk/qemu.sh"
