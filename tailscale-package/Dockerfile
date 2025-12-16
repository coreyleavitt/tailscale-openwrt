# Dockerfile for building Tailscale IPK packages for OpenWrt
# Uses golang image for Go compilation, Tumbleweed for packaging
#
# Build arguments:
#   TAILSCALE_VERSION - Tailscale version to build (e.g., 1.88.3)
#   PACKAGE_VARIANT   - Package variant (glinet-mips24kc or cudy-aarch64)
#   OPENWRT_ARCH      - OpenWrt architecture (mips_24kc or aarch64_cortex-a53)
#   GO_VERSION        - Go version to use (default: 1.23)

# Build arguments (declared before first FROM for global scope)
ARG GO_VERSION=1.23
ARG TAILSCALE_VERSION=1.88.3
ARG PACKAGE_VARIANT=glinet-mips24kc
ARG OPENWRT_ARCH=mips_24kc

# =============================================================================
# Stage 1: Go Build (using official golang image for version control)
# =============================================================================
FROM golang:${GO_VERSION}-alpine AS go-builder

ARG TAILSCALE_VERSION
ARG OPENWRT_ARCH

# Install minimal dependencies for downloading source
RUN apk add --no-cache curl

# Download and extract Tailscale source
WORKDIR /build
RUN curl -L "https://github.com/tailscale/tailscale/archive/refs/tags/v${TAILSCALE_VERSION}.tar.gz" -o tailscale.tar.gz && \
    tar -xzf tailscale.tar.gz && \
    mv tailscale-${TAILSCALE_VERSION} tailscale && \
    rm tailscale.tar.gz

# Build Tailscale binary with size optimizations
WORKDIR /build/tailscale
RUN GOARCH=$(echo ${OPENWRT_ARCH} | grep -q aarch64 && echo arm64 || (echo ${OPENWRT_ARCH} | grep -q mipsel && echo mipsle || echo mips)) && \
    echo "Building for GOARCH=${GOARCH}" && \
    CGO_ENABLED=0 \
    GOOS=linux \
    GOARCH=${GOARCH} \
    GOMIPS=softfloat \
    go build \
        -trimpath \
        -buildvcs=false \
        -tags 'ts_include_cli,ts_omit_aws,ts_omit_bird,ts_omit_tap' \
        -ldflags="-s -w -X tailscale.com/version.longStamp=${TAILSCALE_VERSION} -X tailscale.com/version.shortStamp=${TAILSCALE_VERSION}" \
        -o /build/tailscaled \
        ./cmd/tailscaled

# =============================================================================
# Stage 2: Compress and Package (Tumbleweed for UPX and opkg-build)
# =============================================================================
FROM registry.opensuse.org/opensuse/tumbleweed:latest AS packager

ARG TAILSCALE_VERSION
ARG PACKAGE_VARIANT
ARG OPENWRT_ARCH

# Install packaging dependencies
RUN zypper --non-interactive refresh && \
    zypper --non-interactive install -y \
    upx \
    curl \
    bash \
    tar \
    gzip \
    xz \
    findutils \
    binutils && \
    zypper clean -a

# Download OpenWrt's opkg-build script
RUN curl -o /usr/local/bin/opkg-build \
    https://raw.githubusercontent.com/openwrt/openwrt/openwrt-22.03/scripts/ipkg-build && \
    chmod +x /usr/local/bin/opkg-build

# Copy binary from go-builder stage
COPY --from=go-builder /build/tailscaled /build/tailscaled

# Show original size
RUN echo "Original binary size:" && ls -lh /build/tailscaled

# Compress binary with UPX (try ultra-brute first for best compression)
RUN upx --ultra-brute /build/tailscaled 2>/dev/null || \
    upx --best --lzma /build/tailscaled 2>/dev/null || \
    upx --best /build/tailscaled 2>/dev/null || \
    echo "UPX compression skipped"

# Show compressed size
RUN echo "Compressed binary size:" && ls -lh /build/tailscaled

# Create IPK package structure
WORKDIR /ipk
RUN mkdir -p usr/sbin \
    usr/bin \
    etc/init.d \
    etc/config \
    CONTROL

# Copy binary and create symlink
RUN cp /build/tailscaled usr/sbin/ && \
    chmod 755 usr/sbin/tailscaled && \
    ln -s ../sbin/tailscaled usr/bin/tailscale

# Copy init script, config, and killswitch based on variant
COPY src/ /tmp/files/
RUN VENDOR=$(echo ${PACKAGE_VARIANT} | cut -d'-' -f1) && \
    echo "Building for vendor: $VENDOR" && \
    cp /tmp/files/tailscale.init.$VENDOR etc/init.d/tailscale && \
    cp /tmp/files/tailscale.config.$VENDOR etc/config/tailscale && \
    cp /tmp/files/tailscale-killswitch.sh usr/sbin/tailscale-killswitch

RUN chmod 755 etc/init.d/tailscale && \
    chmod 644 etc/config/tailscale && \
    chmod 755 usr/sbin/tailscale-killswitch

# Create control file with dependencies
RUN VARIANT_NAME=$(echo ${PACKAGE_VARIANT} | cut -d'-' -f1) && \
    DEPS="kmod-tun, ca-bundle" && \
    if [ "$VARIANT_NAME" = "cudy" ]; then DEPS="${DEPS}, ip-full"; fi && \
    cat > CONTROL/control <<EOF
Package: tailscale-${PACKAGE_VARIANT}
Version: ${TAILSCALE_VERSION}-1
Architecture: ${OPENWRT_ARCH}
Maintainer: Community Build
Section: net
Priority: optional
Depends: ${DEPS}
Description: Tailscale VPN client for OpenWrt
 Tailscale is a WireGuard-based mesh VPN that makes it easy to connect
 your devices. This is a community build optimized for ${VARIANT_NAME}
 devices on ${OPENWRT_ARCH} architecture.
 .
 Features:
  - Exit node support with killswitch
  - DNS leak prevention
  - Memory optimized for embedded devices
EOF

# Create conffiles list (preserve user config on upgrade)
RUN echo "/etc/config/tailscale" > CONTROL/conffiles

# Create postinst script
RUN cat > CONTROL/postinst <<'POSTINST'
#!/bin/sh
# Create state directory with secure permissions
mkdir -p /var/lib/tailscale
chmod 700 /var/lib/tailscale

# Create runtime directory
mkdir -p /var/run/tailscale
chmod 755 /var/run/tailscale

# Check for tun module
if ! lsmod | grep -q "^tun "; then
    echo "Note: tun module not loaded. It will be loaded when tailscale starts."
fi

exit 0
POSTINST
RUN chmod 755 CONTROL/postinst

# Create prerm script
RUN cat > CONTROL/prerm <<'PRERM'
#!/bin/sh
# Stop service before removal
if [ -x /etc/init.d/tailscale ]; then
    /etc/init.d/tailscale stop 2>/dev/null || true
    /etc/init.d/tailscale disable 2>/dev/null || true
fi

exit 0
PRERM
RUN chmod 755 CONTROL/prerm

# Create postrm script
RUN cat > CONTROL/postrm <<'POSTRM'
#!/bin/sh
# Clean up runtime files
rm -rf /var/run/tailscale

# Note: /var/lib/tailscale is preserved for reinstallation
# Users can manually remove it if desired:
#   rm -rf /var/lib/tailscale

exit 0
POSTRM
RUN chmod 755 CONTROL/postrm

# Debug: Show directory structure
RUN echo "=== Package contents ===" && \
    find /ipk -type f | sort && \
    echo "=== Control files ===" && \
    cat /ipk/CONTROL/control

# Build the IPK
RUN opkg-build /ipk /tmp && \
    mv /tmp/tailscale-${PACKAGE_VARIANT}_${TAILSCALE_VERSION}-1_${OPENWRT_ARCH}.ipk \
       /tailscale-${PACKAGE_VARIANT}_${TAILSCALE_VERSION}.ipk

# =============================================================================
# Stage 3: Minimal output stage
# =============================================================================
FROM busybox:latest

ARG PACKAGE_VARIANT
ARG TAILSCALE_VERSION

COPY --from=packager /tailscale-${PACKAGE_VARIANT}_${TAILSCALE_VERSION}.ipk /
