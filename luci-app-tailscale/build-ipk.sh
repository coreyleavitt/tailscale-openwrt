#!/bin/bash
# Build luci-app-tailscale IPK package

set -e

PKG_NAME="luci-app-tailscale"
PKG_VERSION="${PKG_VERSION:-1.0}"
ARCH="all"  # LuCI apps are architecture-independent

BUILD_DIR="/tmp/${PKG_NAME}_build"
IPK_DIR="${BUILD_DIR}/ipk"

echo "Building ${PKG_NAME} IPK package..."

# Clean previous build
rm -rf "$BUILD_DIR"
mkdir -p "$IPK_DIR"

# Copy files to IPK structure
echo "Copying files..."
cp -r root/* "$IPK_DIR/" 2>/dev/null || true
mkdir -p "$IPK_DIR/www/luci-static/resources/view/tailscale"
cp -r htdocs/luci-static/resources/view/tailscale/* "$IPK_DIR/www/luci-static/resources/view/tailscale/"

# Set permissions
chmod 755 "$IPK_DIR/usr/libexec/rpcd/luci.tailscale"

# Create CONTROL directory
mkdir -p "$IPK_DIR/CONTROL"

# Create control file
cat > "$IPK_DIR/CONTROL/control" <<EOF
Package: ${PKG_NAME}
Version: ${PKG_VERSION}-1
Architecture: ${ARCH}
Maintainer: Community Build
Section: luci
Priority: optional
Depends: luci-base, rpcd
Description: LuCI interface for Tailscale killswitch management
 Provides a modern web interface for managing Tailscale exit node
 killswitch functionality through LuCI.
 .
 Requires tailscale-killswitch script at /usr/sbin/tailscale-killswitch
EOF

# Create postinst script
cat > "$IPK_DIR/CONTROL/postinst" <<'EOF'
#!/bin/sh
[ -n "$IPKG_INSTROOT" ] || {
	# Check if tailscale-killswitch is available
	if [ ! -x /usr/sbin/tailscale-killswitch ]; then
		echo "WARNING: tailscale-killswitch not found at /usr/sbin/tailscale-killswitch"
		echo "Please install a tailscale package that includes the killswitch script"
	fi
	/etc/init.d/rpcd restart
	/etc/init.d/uhttpd restart
}
exit 0
EOF

chmod 755 "$IPK_DIR/CONTROL/postinst"

# Create prerm script
cat > "$IPK_DIR/CONTROL/prerm" <<'EOF'
#!/bin/sh
exit 0
EOF

chmod 755 "$IPK_DIR/CONTROL/prerm"

# Build IPK using OpenWrt's ipkg-build script
if command -v opkg-build >/dev/null 2>&1; then
	opkg-build "$IPK_DIR" "${BUILD_DIR}"
	mv "${BUILD_DIR}/${PKG_NAME}_${PKG_VERSION}-1_${ARCH}.ipk" "./${PKG_NAME}_${PKG_VERSION}.ipk"
else
	echo "Error: opkg-build not found. Install openwrt-ipkg-build or run in Docker"
	exit 1
fi

echo "Built: ${PKG_NAME}_${PKG_VERSION}.ipk"
