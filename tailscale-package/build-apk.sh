#!/bin/bash
# build-apk.sh -- build the OpenWrt 25 .apk (slice A2, RFC docs/rfc-apk-builds.md
# §3/§4.1). Sibling to build.sh (the ipk path), invoked separately -- it
# targets the additive `apk` Dockerfile stage and never touches the `ipk`
# stage, so it cannot affect build.sh's output.
#
# A5b widened this from one arch (A2 scope) to all four arches.json entries:
# the Dockerfile `apk` stage was already arch-generic (its GOARCH/GOARM/
# GOMIPS mapping already branches on OPENWRT_ARCH for all four cases -- see
# tailscale-package/Dockerfile), so the only generalization needed here is
# looping the existing single-arch build over every arches.json entry. Each
# arch's output stays namespaced under packages/<arch>/ as before.
#
# Usage:
#   build-apk.sh [version] [pkg_release] [arch]
#     arch given  -> build just that one arch (unchanged A2 behavior; this is
#                    how a CI per-arch matrix job or a test invokes it).
#     arch omitted -> build every arch listed in arches.json (repo root),
#                    in order, failing fast on the first error.
set -e

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
ARCHES_JSON="${REPO_ROOT}/arches.json"

VERSION="${1:-1.92.2}"
PKG_RELEASE="${2:-1}"
ARCH="${3:-}"

# Verify version exists
if ! curl -s -f -o /dev/null "https://github.com/tailscale/tailscale/releases/tag/v${VERSION}"; then
    echo "Error: Tailscale version v${VERSION} not found!"
    exit 1
fi

APK_VERSION="${VERSION}-r${PKG_RELEASE}"

build_one() {
    _arch="$1"
    echo "Building Tailscale .apk ${APK_VERSION} for ${_arch}..."
    mkdir -p "packages/${_arch}"

    docker build \
        --progress=plain \
        --target apk \
        --build-arg TAILSCALE_VERSION=${VERSION} \
        --build-arg PKG_RELEASE=${PKG_RELEASE} \
        --build-arg OPENWRT_ARCH=${_arch} \
        -t tailscale-apk-${_arch}:v${VERSION} \
        -f Dockerfile \
        . || { echo "Error: Failed to build ${_arch} .apk"; exit 1; }

    # Extract the .apk using docker cp (arch-namespaced path inside the image
    # -- RFC §3/§4.3: arch goes in the PATH, not the filename, to avoid a
    # same-filename collision across arches during CI artifact merge).
    CONTAINER_ID=$(docker create tailscale-apk-${_arch}:v${VERSION})
    docker cp "${CONTAINER_ID}:/out/${_arch}/tailscale-${APK_VERSION}.apk" "packages/${_arch}/" \
        || { echo "Error: Failed to extract ${_arch} .apk"; docker rm ${CONTAINER_ID} >/dev/null; exit 1; }
    docker rm ${CONTAINER_ID} >/dev/null

    # Validate package
    if [ ! -s "packages/${_arch}/tailscale-${APK_VERSION}.apk" ]; then
        echo "Error: ${_arch} .apk is empty or missing"
        exit 1
    fi

    echo "[OK] ${_arch} .apk built ($(du -h "packages/${_arch}/tailscale-${APK_VERSION}.apk" | cut -f1))"
}

if [ -n "${ARCH}" ]; then
    build_one "${ARCH}"
else
    if ! command -v jq >/dev/null 2>&1; then
        echo "Error: jq is required to build all arches (or pass an explicit arch)" >&2
        exit 1
    fi
    if [ ! -f "${ARCHES_JSON}" ]; then
        echo "Error: ${ARCHES_JSON} not found" >&2
        exit 1
    fi
    for _a in $(jq -r '.[].name' "${ARCHES_JSON}"); do
        build_one "${_a}"
    done
fi
