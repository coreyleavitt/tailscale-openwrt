# Dockerfile for building luci-app-tailscale IPK

ARG PKG_VERSION=1.0

FROM registry.opensuse.org/opensuse/tumbleweed:latest AS builder

ARG PKG_VERSION

# Install opkg-build (this layer will be cached)
RUN zypper --non-interactive refresh && \
    zypper --non-interactive install -y curl bash tar gzip findutils && \
    zypper clean -a && \
    curl -o /usr/local/bin/opkg-build https://raw.githubusercontent.com/openwrt/openwrt/openwrt-22.03/scripts/ipkg-build && \
    chmod +x /usr/local/bin/opkg-build

WORKDIR /build

# Copy build script first (changes rarely)
COPY build-ipk.sh /build/

# Copy source files (changes frequently)
COPY root/ /build/root/
COPY htdocs/ /build/htdocs/

# Build the IPK
RUN PKG_VERSION=${PKG_VERSION} bash build-ipk.sh

# Final minimal output stage
FROM busybox:latest

COPY --from=builder /build/luci-app-tailscale_*.ipk /

CMD ["sh"]
