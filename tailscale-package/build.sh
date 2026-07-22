#!/bin/bash
# build.sh -- build the .ipk (default `docker build` target, the `ipk`
# stage). Both docker build calls below pass `--build-context
# scripts=${REPO_ROOT}/scripts` (RFC docs/rfc-apk-arch-coverage.md §5.1/S3):
# the `ipk` stage's on-device payload now comes from the repo-root
# scripts/stage-payload.sh, which lives outside this Dockerfile's own build
# context (tailscale-package/) -- see the Dockerfile's own top-of-file note.
set -e

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
ARCHES_JSON="${REPO_ROOT}/arches.json"

VERSION="${1:-1.92.2}"
PKG_RELEASE="${2:-1}"
CLEANUP="${CLEANUP:-0}"  # Set CLEANUP=1 to remove intermediate images

# Verify version exists
if ! curl -s -f -o /dev/null "https://github.com/tailscale/tailscale/releases/tag/v${VERSION}"; then
    echo "Error: Tailscale version v${VERSION} not found!"
    exit 1
fi

# jq is needed to look up each arch's full build tuple (goarch/goarm/gomips/
# gomips64/go386) from arches.json -- the Dockerfile no longer derives
# GOARCH from OPENWRT_ARCH's name (RFC docs/rfc-apk-arch-coverage.md
# §5.1/S2), so this script must pass it explicitly, same as build-apk.sh.
if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required" >&2
    exit 1
fi
if [ ! -f "${ARCHES_JSON}" ]; then
    echo "Error: ${ARCHES_JSON} not found" >&2
    exit 1
fi

arch_field() {
    jq -r --arg name "$1" --arg field "$2" '.[] | select(.name == $name) | .[$field] // ""' "${ARCHES_JSON}"
}

echo "Building Tailscale ${VERSION}-${PKG_RELEASE}..."
mkdir -p packages

# MIPS build (mips_24kc - GL.iNet E750/AR750S, etc.)
echo "=== Building mips_24kc package ==="
MIPS_GOARCH=$(arch_field mips_24kc goarch)
MIPS_GOMIPS=$(arch_field mips_24kc gomips)
docker build \
    --progress=plain \
    --build-context scripts="${REPO_ROOT}/scripts" \
    --build-arg TAILSCALE_VERSION=${VERSION} \
    --build-arg PKG_RELEASE=${PKG_RELEASE} \
    --build-arg OPENWRT_ARCH=mips_24kc \
    --build-arg GOARCH=${MIPS_GOARCH} \
    --build-arg GOMIPS=${MIPS_GOMIPS} \
    -t tailscale-mips_24kc:v${VERSION} \
    -f Dockerfile \
    . || { echo "Error: Failed to build mips_24kc package"; exit 1; }

# Extract IPK package using docker cp
CONTAINER_ID=$(docker create tailscale-mips_24kc:v${VERSION})
docker cp ${CONTAINER_ID}:/tailscale_${VERSION}_mips_24kc.ipk packages/ \
    || { echo "Error: Failed to extract mips_24kc package"; exit 1; }
docker rm ${CONTAINER_ID} >/dev/null

# Validate package
if [ ! -s "packages/tailscale_${VERSION}_mips_24kc.ipk" ]; then
    echo "Error: mips_24kc package is empty or missing"
    exit 1
fi

echo "[OK] mips_24kc package built ($(du -h packages/tailscale_${VERSION}_mips_24kc.ipk | cut -f1))"

# Cleanup if requested
if [ "$CLEANUP" = "1" ]; then
    docker rmi tailscale-mips_24kc:v${VERSION}
fi

# aarch64 build (aarch64_cortex-a53 - Cudy TR3000, etc.)
echo ""
echo "=== Building aarch64_cortex-a53 package ==="
AARCH64_GOARCH=$(arch_field aarch64_cortex-a53 goarch)
docker build \
    --progress=plain \
    --build-context scripts="${REPO_ROOT}/scripts" \
    --build-arg TAILSCALE_VERSION=${VERSION} \
    --build-arg PKG_RELEASE=${PKG_RELEASE} \
    --build-arg OPENWRT_ARCH=aarch64_cortex-a53 \
    --build-arg GOARCH=${AARCH64_GOARCH} \
    -t tailscale-aarch64_cortex-a53:v${VERSION} \
    -f Dockerfile \
    . || { echo "Error: Failed to build aarch64_cortex-a53 package"; exit 1; }

# Extract IPK package using docker cp
CONTAINER_ID=$(docker create tailscale-aarch64_cortex-a53:v${VERSION})
docker cp ${CONTAINER_ID}:/tailscale_${VERSION}_aarch64_cortex-a53.ipk packages/ \
    || { echo "Error: Failed to extract aarch64_cortex-a53 package"; exit 1; }
docker rm ${CONTAINER_ID} >/dev/null

# Validate package
if [ ! -s "packages/tailscale_${VERSION}_aarch64_cortex-a53.ipk" ]; then
    echo "Error: aarch64_cortex-a53 package is empty or missing"
    exit 1
fi

echo "[OK] aarch64_cortex-a53 package built ($(du -h packages/tailscale_${VERSION}_aarch64_cortex-a53.ipk | cut -f1))"

# Cleanup if requested
if [ "$CLEANUP" = "1" ]; then
    docker rmi tailscale-aarch64_cortex-a53:v${VERSION}
fi

# Generate checksums
cd packages
sha256sum *.ipk > SHA256SUMS
cd ..

# Summary
echo ""
echo "======================================="
echo "Build complete for Tailscale ${VERSION}-${PKG_RELEASE}"
echo "======================================="
echo "Packages built:"
ls -lh packages/*.ipk
echo ""
echo "Installation:"
echo "  mips_24kc (GL.iNet E750/AR750S):     opkg install tailscale_${VERSION}_mips_24kc.ipk"
echo "  aarch64_cortex-a53 (Cudy TR3000):    opkg install tailscale_${VERSION}_aarch64_cortex-a53.ipk"
