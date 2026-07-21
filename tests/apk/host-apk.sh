#!/bin/sh
# tests/apk/host-apk.sh
#
# Slice A1 test: build the `apk-tools` stage of tailscale-package/Dockerfile
# (isolated so this builds fast, without running the full Go/UPX/ipk build)
# and assert, inside that stage's image, that:
#   - `apk --version` reports the pinned 3.0.2 (matches what OpenWrt 25.12.0
#     ships -- see arches.json / tests/apk/rootfs.sh)
#   - the `mkpkg` and `mkndx` maintainer applets are present and functional
#     (A2 depends on `apk mkpkg` working on this x86_64 build host)
#
# Applet-presence note: this apk-tools build exits 1 for --help on *every*
# applet, including unknown ones (confirmed empirically) -- so exit code
# alone cannot distinguish "applet present" from "applet unknown, fell back
# to top-level usage". Instead this test greps for the applet-specific
# "Mkpkg options:" / "Mkndx options:" section header, which apk only prints
# when it recognized the applet name; an unknown applet falls back to the
# generic top-level command list and never prints that header.
#
# Uses the shared tests/apk/lib.sh harness (established slice A2).
#
# Usage: sh tests/apk/host-apk.sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
PKG_DIR="${REPO_ROOT}/tailscale-package"

# shellcheck source=tests/apk/lib.sh
. "${SCRIPT_DIR}/lib.sh"

require_cmd docker

IMAGE_TAG="tailscale-apk-tools-test:latest"

if [ ! -f "${PKG_DIR}/Dockerfile" ]; then
    echo "FAIL: ${PKG_DIR}/Dockerfile not found" >&2
    exit 1
fi

echo "Building apk-tools stage from ${PKG_DIR}/Dockerfile..."
if ! docker build --target apk-tools -t "${IMAGE_TAG}" -f "${PKG_DIR}/Dockerfile" "${PKG_DIR}"; then
    log_fail "docker build --target apk-tools failed"
    harness_finish "tests/apk/host-apk.sh"
fi

if ! VERSION_OUT=$(docker run --rm --entrypoint apk "${IMAGE_TAG}" --version 2>&1); then
    log_fail "'apk --version' failed in apk-tools stage (${VERSION_OUT})"
else
    echo "apk --version: ${VERSION_OUT}"
    assert_contains "apk --version" "${VERSION_OUT}" "3.0.2"
fi

# --help always exits non-zero on this apk build (even for unknown applets),
# so don't gate on exit code -- gate on the applet-specific help section,
# which only a recognized applet prints.
MKPKG_OUT=$(docker run --rm --entrypoint apk "${IMAGE_TAG}" mkpkg --help 2>&1 || true)
assert_contains "apk mkpkg --help" "${MKPKG_OUT}" "Mkpkg options:"

MKNDX_OUT=$(docker run --rm --entrypoint apk "${IMAGE_TAG}" mkndx --help 2>&1 || true)
assert_contains "apk mkndx --help" "${MKNDX_OUT}" "Mkndx options:"

harness_finish "tests/apk/host-apk.sh"
