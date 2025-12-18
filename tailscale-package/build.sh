#!/bin/bash
set -e

VERSION="${1:-1.92.2}"
CLEANUP="${CLEANUP:-0}"  # Set CLEANUP=1 to remove intermediate images

# Verify version exists
if ! curl -s -f -o /dev/null "https://github.com/tailscale/tailscale/releases/tag/v${VERSION}"; then
    echo "Error: Tailscale version v${VERSION} not found!"
    exit 1
fi

echo "Building Tailscale ${VERSION}..."
mkdir -p packages

# MIPS build (mips_24kc - GL.iNet E750/AR750S, etc.)
echo "=== Building mips_24kc package ==="
docker build \
    --progress=plain \
    --build-arg TAILSCALE_VERSION=${VERSION} \
    --build-arg OPENWRT_ARCH=mips_24kc \
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
docker build \
    --progress=plain \
    --build-arg TAILSCALE_VERSION=${VERSION} \
    --build-arg OPENWRT_ARCH=aarch64_cortex-a53 \
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
echo "Build complete for Tailscale ${VERSION}"
echo "======================================="
echo "Packages built:"
ls -lh packages/*.ipk
echo ""
echo "Installation:"
echo "  mips_24kc (GL.iNet E750/AR750S):     opkg install tailscale_${VERSION}_mips_24kc.ipk"
echo "  aarch64_cortex-a53 (Cudy TR3000):    opkg install tailscale_${VERSION}_aarch64_cortex-a53.ipk"
