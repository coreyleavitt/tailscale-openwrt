# Dockerfile for building Tailscale IPK packages for OpenWrt
# Single-stage build using Tumbleweed for Go compilation, UPX compression, and packaging
#
# Build arguments:
#   TAILSCALE_VERSION - Tailscale version to build (e.g., 1.92.2)
#   OPENWRT_ARCH      - OpenWrt architecture (mips_24kc or aarch64_cortex-a53)

ARG TAILSCALE_VERSION=1.92.2
ARG OPENWRT_ARCH=mips_24kc
ARG SKIP_UPX=0

FROM registry.opensuse.org/opensuse/tumbleweed:latest

ARG TAILSCALE_VERSION
ARG OPENWRT_ARCH
ARG SKIP_UPX

# Install all build dependencies
RUN zypper --non-interactive refresh && \
    zypper --non-interactive install -y \
    go \
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

# Download and extract Tailscale source
WORKDIR /build
RUN curl -L "https://github.com/tailscale/tailscale/archive/refs/tags/v${TAILSCALE_VERSION}.tar.gz" -o tailscale.tar.gz && \
    tar -xzf tailscale.tar.gz && \
    mv tailscale-${TAILSCALE_VERSION} tailscale && \
    rm tailscale.tar.gz

# Build Tailscale binary with size optimizations
# GOTOOLCHAIN=auto downloads whatever Go version Tailscale requires
WORKDIR /build/tailscale
RUN GOARCH=$(echo ${OPENWRT_ARCH} | grep -q aarch64 && echo arm64 || (echo ${OPENWRT_ARCH} | grep -q mipsel && echo mipsle || echo mips)) && \
    echo "Building for GOARCH=${GOARCH}" && \
    GOTOOLCHAIN=auto \
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

# Show original size
RUN echo "Original binary size:" && ls -lh /build/tailscaled

# Compress binary with UPX (skip with --build-arg SKIP_UPX=1 for faster testing)
# Using --best --lzma instead of --ultra-brute for much faster builds.
# Testing showed ultra-brute selects LZMA method 14 level 10 for both archs.
# Results: MIPS identical, ARM64 is 38KB larger (0.5%) - acceptable trade-off.
RUN if [ "$SKIP_UPX" = "1" ]; then \
        echo "UPX compression skipped (SKIP_UPX=1)"; \
    else \
        upx --best --lzma /build/tailscaled 2>/dev/null || \
        upx --best /build/tailscaled 2>/dev/null || \
        echo "UPX compression failed, continuing without"; \
    fi

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

# Copy unified init script, config, and killswitch
COPY src/ /tmp/files/
RUN cp /tmp/files/tailscale.init etc/init.d/tailscale && \
    cp /tmp/files/tailscale.config etc/config/tailscale && \
    cp /tmp/files/tailscale-killswitch.sh usr/sbin/tailscale-killswitch

RUN chmod 755 etc/init.d/tailscale && \
    chmod 644 etc/config/tailscale && \
    chmod 755 usr/sbin/tailscale-killswitch

# Create control file
RUN cat > CONTROL/control <<EOF
Package: tailscale
Version: ${TAILSCALE_VERSION}-1
Architecture: ${OPENWRT_ARCH}
Maintainer: Community Build
Section: net
Priority: optional
Depends: kmod-tun, ca-bundle, ip-full
Description: Tailscale VPN client for OpenWrt
 Tailscale is a WireGuard-based mesh VPN that makes it easy to connect
 your devices. Auto-detects hardware and optimizes for available RAM.
 .
 Features:
  - Exit node support with killswitch
  - DNS leak prevention
  - Auto-tuned for device memory
EOF

# Create conffiles list (preserve user config on upgrade)
RUN echo "/etc/config/tailscale" > CONTROL/conffiles

# Copy postinst script (handles hardware detection)
RUN cp /tmp/files/tailscale.postinst CONTROL/postinst && \
    chmod 755 CONTROL/postinst

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
    mv /tmp/tailscale_${TAILSCALE_VERSION}-1_${OPENWRT_ARCH}.ipk \
       /tailscale_${TAILSCALE_VERSION}_${OPENWRT_ARCH}.ipk

# Final output location
# Extract with: docker run --rm <image> cat /tailscale_*.ipk > package.ipk
