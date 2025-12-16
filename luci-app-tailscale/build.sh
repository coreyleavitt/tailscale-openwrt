#!/bin/bash
# Build script for luci-app-tailscale
# Usage: ./build.sh [version]

set -e

VERSION=${1:-1.0}
CLEANUP="${CLEANUP:-0}"  # Set CLEANUP=1 to remove Docker images
PKG_NAME="luci-app-tailscale"
OUTPUT_DIR="../packages"

echo "========================================"
echo "Building ${PKG_NAME} v${VERSION}"
echo "========================================"

# Clean previous IPK builds
echo "Cleaning previous IPK builds..."
rm -f "${PKG_NAME}_${VERSION}.ipk"

# Build Docker image
echo ""
echo "Building Docker image..."
docker build \
    --build-arg PKG_VERSION=${VERSION} \
    -t ${PKG_NAME}:v${VERSION} \
    -f Dockerfile \
    .

# Extract IPK from container
echo ""
echo "Extracting IPK package..."
docker run --rm ${PKG_NAME}:v${VERSION} cat /${PKG_NAME}_${VERSION}.ipk > ${PKG_NAME}_${VERSION}.ipk

# Create output directory if needed
mkdir -p "${OUTPUT_DIR}"

# Move to output directory
echo ""
echo "Moving to ${OUTPUT_DIR}/"
mv ${PKG_NAME}_${VERSION}.ipk "${OUTPUT_DIR}/"

# Cleanup if requested
if [ "$CLEANUP" = "1" ]; then
	echo ""
	echo "Cleaning up Docker images..."
	docker rmi ${PKG_NAME}:v${VERSION} 2>/dev/null || true
fi

# Show file info
echo ""
echo "========================================"
echo "Build complete!"
echo "========================================"
ls -lh "${OUTPUT_DIR}/${PKG_NAME}_${VERSION}.ipk"
echo ""
echo "Install with:"
echo "  scp ${OUTPUT_DIR}/${PKG_NAME}_${VERSION}.ipk root@<router-ip>:/tmp/"
echo "  ssh root@<router-ip> 'opkg install /tmp/${PKG_NAME}_${VERSION}.ipk && /etc/init.d/rpcd restart && /etc/init.d/uhttpd restart'"
echo ""
echo "To cleanup Docker cache, run:"
echo "  CLEANUP=1 ./build.sh ${VERSION}"
echo ""
