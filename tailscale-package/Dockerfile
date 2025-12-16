# Dockerfile for building Tailscale IPK packages directly (no OpenWrt SDK)
# Supports: mips_24kc (GL.iNet E750/AR750S), mipsel_24kc (Cudy TR3000)

# Build arguments
ARG TAILSCALE_VERSION=1.88.3
ARG PACKAGE_VARIANT=glinet-mips24kc
ARG OPENWRT_ARCH=mips_24kc

# Build stage
FROM registry.opensuse.org/opensuse/tumbleweed:latest AS builder

ARG TAILSCALE_VERSION
ARG PACKAGE_VARIANT
ARG OPENWRT_ARCH

# Install build dependencies
RUN zypper --non-interactive refresh && \
    zypper --non-interactive install -y \
    go \
    upx \
    curl \
    tar \
    bash \
    gzip && \
    zypper clean -a

# Download and extract Tailscale source
WORKDIR /build
RUN curl -L "https://github.com/tailscale/tailscale/archive/refs/tags/v${TAILSCALE_VERSION}.tar.gz" -o tailscale.tar.gz && \
    tar -xzf tailscale.tar.gz && \
    mv tailscale-${TAILSCALE_VERSION} tailscale && \
    rm tailscale.tar.gz

# Build Tailscale binary
WORKDIR /build/tailscale
RUN CGO_ENABLED=0 \
    GOOS=linux \
    GOARCH=$(echo ${OPENWRT_ARCH} | grep -q aarch64 && echo arm64 || (echo ${OPENWRT_ARCH} | grep -q mipsel && echo mipsle || echo mips)) \
    GOMIPS=softfloat \
    go build \
        -tags ts_include_cli \
        -ldflags="-s -w -X tailscale.com/version.longStamp=${TAILSCALE_VERSION} -X tailscale.com/version.shortStamp=${TAILSCALE_VERSION}" \
        -o /build/tailscaled \
        ./cmd/tailscaled

# Compress binary with UPX
RUN upx --best /build/tailscaled 2>/dev/null || \
    upx --ultra-brute /build/tailscaled 2>/dev/null || \
    echo "UPX compression skipped"

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
# Extract vendor name (glinet or cudy) from PACKAGE_VARIANT
RUN VENDOR=$(echo ${PACKAGE_VARIANT} | cut -d'-' -f1) && \
    echo "Vendor: $VENDOR"

COPY src/ /tmp/files/
RUN VENDOR=$(echo ${PACKAGE_VARIANT} | cut -d'-' -f1) && \
    cp /tmp/files/tailscale.init.$VENDOR etc/init.d/tailscale && \
    cp /tmp/files/tailscale.config.$VENDOR etc/config/tailscale && \
    cp /tmp/files/tailscale-killswitch.sh usr/sbin/tailscale-killswitch
RUN chmod 755 etc/init.d/tailscale && \
    chmod 644 etc/config/tailscale && \
    chmod 755 usr/sbin/tailscale-killswitch

# Create control file
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
Description: Tailscale VPN client
 Tailscale is a WireGuard-based VPN that makes it easy to connect your devices,
 wherever they are. This is a community build for OpenWrt routers.
 .
 Optimized for ${VARIANT_NAME} devices on ${OPENWRT_ARCH} architecture.
EOF

# Create conffiles list
RUN echo "/etc/config/tailscale" > CONTROL/conffiles

# Package stage - install opkg-utils and build IPK
FROM registry.opensuse.org/opensuse/tumbleweed:latest AS packager

ARG TAILSCALE_VERSION
ARG PACKAGE_VARIANT
ARG OPENWRT_ARCH

# Install dependencies and download OpenWrt's opkg-build script
RUN zypper --non-interactive refresh && \
    zypper --non-interactive install -y curl bash tar gzip findutils binutils && \
    zypper clean -a && \
    curl -o /usr/local/bin/opkg-build https://raw.githubusercontent.com/openwrt/openwrt/openwrt-22.03/scripts/ipkg-build && \
    chmod +x /usr/local/bin/opkg-build

WORKDIR /ipk
COPY --from=builder /ipk /ipk

# Debug: Show directory structure
RUN ls -la /ipk && ls -la /ipk/etc && ls -la /ipk/etc/config && ls -la /ipk/CONTROL

# Build the IPK
RUN opkg-build /ipk /tmp && \
    mv /tmp/tailscale-${PACKAGE_VARIANT}_${TAILSCALE_VERSION}-1_${OPENWRT_ARCH}.ipk \
       /tailscale-${PACKAGE_VARIANT}_${TAILSCALE_VERSION}.ipk

# Final minimal output stage
FROM busybox:latest

ARG PACKAGE_VARIANT
ARG TAILSCALE_VERSION
ARG OPENWRT_ARCH

COPY --from=packager /tailscale-${PACKAGE_VARIANT}_${TAILSCALE_VERSION}.ipk /
