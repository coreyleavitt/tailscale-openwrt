#!/bin/bash
set -e

VERSION="${1:-1.88.3}"
CLEANUP="${CLEANUP:-0}"  # Set CLEANUP=1 to remove intermediate images

# Verify version exists
if ! curl -s -f -o /dev/null "https://github.com/tailscale/tailscale/releases/tag/v${VERSION}"; then
    echo "Error: Tailscale version v${VERSION} not found!"
    exit 1
fi

echo "Building Tailscale ${VERSION} using direct IPK packaging..."
mkdir -p packages

# GL.iNet build (mips_24kc - OpenWrt 22.03.4)
echo "=== Building GL.iNet package (mips_24kc) ==="
docker build \
    --progress=plain \
    --build-arg TAILSCALE_VERSION=${VERSION} \
    --build-arg PACKAGE_VARIANT=glinet-mips24kc \
    --build-arg OPENWRT_ARCH=mips_24kc \
    -t tailscale-glinet-mips24kc:v${VERSION} \
    -f Dockerfile \
    . || { echo "Error: Failed to build GL.iNet package"; exit 1; }

# Extract IPK package using docker cp
CONTAINER_ID=$(docker create tailscale-glinet-mips24kc:v${VERSION})
docker cp ${CONTAINER_ID}:/tailscale-glinet-mips24kc_${VERSION}.ipk packages/ \
    || { echo "Error: Failed to extract GL.iNet package"; exit 1; }
docker rm ${CONTAINER_ID} >/dev/null

# Validate package
if [ ! -s "packages/tailscale-glinet-mips24kc_${VERSION}.ipk" ]; then
    echo "Error: GL.iNet package is empty or missing"
    exit 1
fi

echo "[OK] GL.iNet package built ($(du -h packages/tailscale-glinet-mips24kc_${VERSION}.ipk | cut -f1))"

# Cleanup if requested
if [ "$CLEANUP" = "1" ]; then
    docker rmi tailscale-glinet-mips24kc:v${VERSION}
fi

# Cudy build (aarch64_cortex-a53 - OpenWrt 24.10.3)
echo ""
echo "=== Building Cudy package (aarch64_cortex-a53) ==="
docker build \
    --progress=plain \
    --build-arg TAILSCALE_VERSION=${VERSION} \
    --build-arg PACKAGE_VARIANT=cudy-aarch64 \
    --build-arg OPENWRT_ARCH=aarch64_cortex-a53 \
    -t tailscale-cudy-aarch64:v${VERSION} \
    -f Dockerfile \
    . || { echo "Error: Failed to build Cudy package"; exit 1; }

# Extract IPK package using docker cp
CONTAINER_ID=$(docker create tailscale-cudy-aarch64:v${VERSION})
docker cp ${CONTAINER_ID}:/tailscale-cudy-aarch64_${VERSION}.ipk packages/ \
    || { echo "Error: Failed to extract Cudy package"; exit 1; }
docker rm ${CONTAINER_ID} >/dev/null

# Validate package
if [ ! -s "packages/tailscale-cudy-aarch64_${VERSION}.ipk" ]; then
    echo "Error: Cudy package is empty or missing"
    exit 1
fi

echo "[OK] Cudy package built ($(du -h packages/tailscale-cudy-aarch64_${VERSION}.ipk | cut -f1))"

# Cleanup if requested
if [ "$CLEANUP" = "1" ]; then
    docker rmi tailscale-cudy-aarch64:v${VERSION}
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
echo "  GL.iNet (E750/AR750S): opkg install tailscale-glinet-mips24kc_${VERSION}.ipk"
echo "  Cudy TR3000:           opkg install tailscale-cudy-aarch64_${VERSION}.ipk"
