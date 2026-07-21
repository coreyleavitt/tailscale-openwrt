#!/bin/sh
# tests/apk/rootfs.sh
#
# Slice A0 test: for every arch in arches.json, download the pinned OpenWrt
# 25.12 rootfs, verify its sha256 against the pin (fail loudly on mismatch),
# `docker import` it to a tagged image, and assert inside the container that
# `apk` is v3 and record `apk --print-arch`.
#
# Uses the shared tests/apk/lib.sh harness (established slice A2). Safe to
# re-run; skips re-download when the cached file already matches the pin.
#
# Emulation note: on an x86-64 CI runner all four pinned rootfs images need
# qemu-user emulation to exec `apk` inside `docker run`. Standard qemu
# binfmt setup (`docker/setup-qemu-action`, `tonistiigi/binfmt`) does not
# register 32-bit MIPS at all, and even a manual `multiarch/qemu-user-static`
# registration rejects OpenWrt's musl mips/mipsel (softfloat) binaries: their
# ELF e_ident[EI_ABIVERSION] byte is 1, but the stock qemu-mips/qemu-mipsel
# binfmt_misc entries require that byte to be 0, so they exec-fail with
# "exec format error" even though qemu itself supports the ISA fine. This
# script detects that failure and self-heals by registering OpenWrt-specific
# mips/mipsel binfmt_misc entries with that byte wildcarded (requires
# --privileged docker; done lazily, only if a plain `apk --version` fails).
#
# Usage: sh tests/apk/rootfs.sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
ARCHES_JSON="${REPO_ROOT}/arches.json"
CACHE_DIR="${ROOTFS_CACHE_DIR:-${SCRIPT_DIR}/.cache}"

# shellcheck source=tests/apk/lib.sh
. "${SCRIPT_DIR}/lib.sh"

BINFMT_SETUP_DONE=0

# Register qemu-user emulation for arm/aarch64 (standard) and for OpenWrt's
# musl mips/mipsel softfloat binaries (custom mask, see header comment
# above). Runs at most once per script invocation. Requires --privileged
# docker; only invoked lazily, when a container actually fails to exec.
# Shared with tests/apk/qemu.sh (A5a) via lib.sh's
# register_standard_qemu_binfmt/register_openwrt_mips_binfmt.
ensure_binfmt() {
    if [ "${BINFMT_SETUP_DONE}" -eq 1 ]; then
        return 0
    fi
    BINFMT_SETUP_DONE=1

    if [ "${ROOTFS_SKIP_BINFMT_SETUP:-0}" = "1" ]; then
        echo "ROOTFS_SKIP_BINFMT_SETUP=1: not attempting binfmt setup" >&2
        return 0
    fi

    echo "Registering qemu-user binfmt emulators (multiarch/qemu-user-static)..." >&2
    if ! register_standard_qemu_binfmt; then
        echo "WARN: multiarch/qemu-user-static --reset failed (continuing; container execs may still fail)" >&2
    fi

    register_openwrt_mips_binfmt || echo "WARN: OpenWrt mips/mipsel binfmt registration failed (continuing; mips/mipsel containers may fail)" >&2
}

# Run `docker run --rm "$1" $2 $3 ...`, capturing combined output. On the
# "exec format error" failure class, register emulation once and retry.
run_in_container() {
    image="$1"
    shift
    out=$(docker run --rm "${image}" "$@" 2>&1) && { printf '%s' "${out}"; return 0; }
    case "${out}" in
        *"exec format error"*)
            ensure_binfmt
            out=$(docker run --rm "${image}" "$@" 2>&1) && { printf '%s' "${out}"; return 0; }
            ;;
    esac
    printf '%s' "${out}"
    return 1
}

require_cmd jq
require_cmd docker

if [ ! -f "${ARCHES_JSON}" ]; then
    echo "FAIL: ${ARCHES_JSON} not found" >&2
    exit 1
fi

mkdir -p "${CACHE_DIR}"

COUNT=$(jq 'length' "${ARCHES_JSON}")
if [ "${COUNT}" -eq 0 ]; then
    echo "FAIL: arches.json contains no arches" >&2
    exit 1
fi

i=0
while [ "$i" -lt "$COUNT" ]; do
    NAME=$(jq -r ".[$i].name" "${ARCHES_JSON}")
    URL=$(jq -r ".[$i].rootfs_url" "${ARCHES_JSON}")
    PIN=$(jq -r ".[$i].rootfs_sha256" "${ARCHES_JSON}")
    EXPECT_CONTAINER_ARCH=$(jq -r ".[$i].container_arch" "${ARCHES_JSON}")
    i=$((i + 1))

    echo "=== ${NAME} ==="

    if [ -z "${NAME}" ] || [ "${NAME}" = "null" ]; then
        log_fail "arches.json entry $i missing 'name'"
        continue
    fi
    if [ -z "${URL}" ] || [ "${URL}" = "null" ]; then
        log_fail "${NAME}: missing rootfs_url"
        continue
    fi
    if [ -z "${PIN}" ] || [ "${PIN}" = "null" ]; then
        log_fail "${NAME}: missing rootfs_sha256"
        continue
    fi

    DEST="${CACHE_DIR}/$(basename "${URL}")"

    # Skip re-download if a cached file already matches the pin.
    NEED_DOWNLOAD=1
    if [ -f "${DEST}" ]; then
        ACTUAL=$(sha256sum "${DEST}" | awk '{print $1}')
        if [ "${ACTUAL}" = "${PIN}" ]; then
            NEED_DOWNLOAD=0
        fi
    fi

    if [ "${NEED_DOWNLOAD}" -eq 1 ]; then
        echo "Downloading ${URL}"
        if ! curl -fsSL -o "${DEST}.part" "${URL}"; then
            log_fail "${NAME}: download failed for ${URL}"
            rm -f "${DEST}.part"
            continue
        fi
        mv "${DEST}.part" "${DEST}"
    fi

    ACTUAL=$(sha256sum "${DEST}" | awk '{print $1}')
    if [ "${ACTUAL}" != "${PIN}" ]; then
        log_fail "${NAME}: sha256 mismatch for ${DEST} (expected ${PIN}, got ${ACTUAL})"
        rm -f "${DEST}"
        continue
    fi
    echo "sha256 OK (${ACTUAL})"

    IMAGE_TAG="owrt2512-rootfs:${NAME}"
    if ! docker import "${DEST}" "${IMAGE_TAG}" >/dev/null; then
        log_fail "${NAME}: docker import failed"
        continue
    fi

    if ! APK_VERSION=$(run_in_container "${IMAGE_TAG}" apk --version); then
        log_fail "${NAME}: 'apk --version' failed in container (${APK_VERSION})"
        continue
    fi
    case "${APK_VERSION}" in
        *"apk-tools 3."*) ;;
        *)
            log_fail "${NAME}: expected apk-tools v3, got: ${APK_VERSION}"
            continue
            ;;
    esac
    echo "apk --version: ${APK_VERSION}"

    if ! CONTAINER_ARCH=$(run_in_container "${IMAGE_TAG}" apk --print-arch); then
        log_fail "${NAME}: 'apk --print-arch' failed in container (${CONTAINER_ARCH})"
        continue
    fi
    echo "apk --print-arch: ${CONTAINER_ARCH}"

    if [ -n "${EXPECT_CONTAINER_ARCH}" ] && [ "${EXPECT_CONTAINER_ARCH}" != "null" ]; then
        if [ "${CONTAINER_ARCH}" != "${EXPECT_CONTAINER_ARCH}" ]; then
            log_fail "${NAME}: apk --print-arch reported '${CONTAINER_ARCH}', arches.json pins '${EXPECT_CONTAINER_ARCH}'"
            continue
        fi
    fi

    echo "OK: ${NAME}"
    echo
done

harness_finish "tests/apk/rootfs.sh"
