# Dockerfile for building Tailscale IPK packages for OpenWrt
# Single-stage build using Tumbleweed for Go compilation, UPX compression, and packaging
#
# Build arguments:
#   TAILSCALE_VERSION - Tailscale version to build (e.g., 1.92.2)
#   OPENWRT_ARCH      - OpenWrt architecture (mips_24kc or aarch64_cortex-a53)
#   PKG_RELEASE       - Package release number (default: 1)
#   GOARM             - Go ARM float ABI (e.g. "5" for softfloat, "7" for
#                       hard-float); should come from arches.json's per-arch
#                       goarm field, not be guessed from OPENWRT_ARCH's name.
#   GOMIPS            - Go MIPS float ABI (e.g. "softfloat"); ditto, from
#                       arches.json's gomips field. Defaults to "softfloat"
#                       when unset.

ARG TAILSCALE_VERSION=1.92.2
ARG OPENWRT_ARCH=mips_24kc
ARG PKG_RELEASE=1
ARG SKIP_UPX=0
ARG GLINET_VARIANT=0
# GOARM/GOMIPS: optional overrides, normally sourced from arches.json by
# build-apk.sh/build.sh's caller and passed as --build-arg. Left empty by
# default so this stage falls back to its own OPENWRT_ARCH-derived values
# below for any caller that doesn't pass them explicitly.
ARG GOARM=
ARG GOMIPS=

# Host apk-tools 3, pinned to the version OpenWrt 25.12.0 ships (3.0.2), for
# `apk mkpkg`/`apk mkndx` (A2 packages the .apk with these). O3 (see
# docs/rfc-apk-builds.md): extract just the host apk binary from the OpenWrt
# 25.12.0 x86_64 SDK's staging_dir/host/bin rather than building apk-tools
# from source -- it's byte-identical to OpenWrt's own build infra.
#
# staging_dir/host/bin/apk itself is a *wrapper shell script* that execs a
# hidden `.apk.bin` via the SDK's own bundled ld.so/lib path (OpenWrt's usual
# trick for host tools built against a specific glibc). Empirically (A1),
# `.apk.bin` is a normal dynamic ELF needing only libc.so.6/libpthread.so.0
# (glibc >= 2.28) and runs directly on opensuse/tumbleweed's glibc with no
# custom interpreter or bundled libs required -- so we extract *only*
# `.apk.bin`, not the wrapper or staging_dir/host/lib.
#
# Pinned by URL + sha256 (sha256 taken from the target's published
# `sha256sums`, https://downloads.openwrt.org/releases/25.12.0/targets/x86/64/sha256sums).
FROM registry.opensuse.org/opensuse/tumbleweed:latest AS apk-tools

ARG OPENWRT_SDK_URL=https://downloads.openwrt.org/releases/25.12.0/targets/x86/64/openwrt-sdk-25.12.0-x86-64_gcc-14.3.0_musl.Linux-x86_64.tar.zst
ARG OPENWRT_SDK_SHA256=9f371906ce6d2f95418f69fac06df58bf9df0ffc4abed6206c30f1b547fcfc12

RUN zypper --non-interactive refresh && \
    zypper --non-interactive install -y curl tar zstd && \
    zypper clean -a

RUN curl -fsSL -o /tmp/openwrt-sdk.tar.zst "${OPENWRT_SDK_URL}" && \
    echo "${OPENWRT_SDK_SHA256}  /tmp/openwrt-sdk.tar.zst" | sha256sum -c - && \
    tar --zstd -xf /tmp/openwrt-sdk.tar.zst -O --wildcards '*/staging_dir/host/bin/.apk.bin' > /usr/local/bin/apk && \
    chmod 755 /usr/local/bin/apk && \
    rm /tmp/openwrt-sdk.tar.zst

# Sanity-check the extracted binary at build time -- fail the build loudly if
# the version drifts from the pin or an applet goes missing, rather than
# silently shipping a broken/mismatched apk (this is exactly what
# tests/apk/host-apk.sh also asserts from the outside).
RUN /usr/local/bin/apk --version | grep -q ' 3\.0\.2,' && \
    /usr/local/bin/apk mkpkg --help 2>&1 | grep -q 'Mkpkg options:' && \
    /usr/local/bin/apk mkndx --help 2>&1 | grep -q 'Mkndx options:'

FROM registry.opensuse.org/opensuse/tumbleweed:latest AS build

ARG TAILSCALE_VERSION
ARG OPENWRT_ARCH
ARG PKG_RELEASE
ARG SKIP_UPX
ARG GOARM
ARG GOMIPS

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

# Host apk-tools 3.0.2 (mkpkg/mkndx) -- see the apk-tools stage above.
#
# fakeroot verdict (RFC §3): NOT load-bearing here, dropped. Confirmed
# empirically (A1) -- `apk mkpkg` never consults the live filesystem's
# uid/gid at all (a file explicitly chowned to a non-root uid is still
# recorded in the package as `user: nobody, group: nobody`), so there is
# nothing for fakeroot to fake, root-context RUN or not.
COPY --from=apk-tools /usr/local/bin/apk /usr/local/bin/apk

# Download OpenWrt's opkg-build script
RUN curl -o /usr/local/bin/opkg-build \
    https://raw.githubusercontent.com/openwrt/openwrt/openwrt-22.03/scripts/ipkg-build && \
    chmod +x /usr/local/bin/opkg-build

# Download and extract Tailscale source
WORKDIR /build
# tailscale.tar.gz is intentionally kept (not rm'd) -- the apk stage below
# reads its mtime for SOURCE_DATE_EPOCH (RFC §3: GitHub sets archive mtimes
# to the tagged commit time, so this is stable across re-runs of the same
# tailscale_version, unlike `git log` against this repo's own HEAD -- and
# there is no .git in this build context anyway).
RUN curl -L "https://github.com/tailscale/tailscale/archive/refs/tags/v${TAILSCALE_VERSION}.tar.gz" -o tailscale.tar.gz && \
    tar -xzf tailscale.tar.gz && \
    mv tailscale-${TAILSCALE_VERSION} tailscale

# Build Tailscale binary with size optimizations
# GOTOOLCHAIN=auto downloads whatever Go version Tailscale requires
# GOARCH is always derived from OPENWRT_ARCH's name (arch family never
# changes). GOARM/GOMIPS are NOT re-derived from the name -- they come
# straight from the GOARM/GOMIPS build args (sourced from arches.json's
# per-arch goarm/gomips fields by the caller, e.g. build-apk.sh), since a
# single OPENWRT_ARCH family can span multiple float ABIs (e.g. the bare,
# FPU-less `arm_cortex-a7` package arch needs GOARM=5/softfloat, while a
# hypothetical `cortex-a7_vfpv4` needs GOARM=7/hard-float -- guessing from
# the name alone previously hardcoded GOARM=7 for every arm_cortex* name
# and shipped a hard-float binary that SIGILLs on genuinely FPU-less
# silicon even though `apk add` reports success). GOMIPS defaults to
# "softfloat" when not passed, since every mips/mipsel arch currently
# shipped needs it and Go ignores GOMIPS for non-mips GOARCH anyway.
#   aarch64*     -> arm64
#   arm_cortex*  -> arm
#   mipsel*      -> mipsle
#   mips*        -> mips
WORKDIR /build/tailscale
RUN GOARCH=$(case "${OPENWRT_ARCH}" in \
      aarch64*) echo "arm64" ;; \
      arm_cortex*) echo "arm" ;; \
      mipsel*) echo "mipsle" ;; \
      *) echo "mips" ;; \
    esac) && \
    if [ -z "${GOMIPS}" ]; then \
      GOMIPS="softfloat"; \
    fi && \
    echo "Building for GOARCH=${GOARCH} GOARM=${GOARM} GOMIPS=${GOMIPS}" && \
    GOTOOLCHAIN=auto \
    CGO_ENABLED=0 \
    GOOS=linux \
    GOARCH=${GOARCH} \
    GOARM=${GOARM} \
    GOMIPS=${GOMIPS} \
    go build \
        -trimpath \
        -buildvcs=false \
        -tags 'ts_include_cli,ts_omit_aws,ts_omit_bird,ts_omit_tap,ts_omit_clientupdate' \
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

# Payload sources, shared by both the ipk and apk stages below.
# Note: netifd protocol handler intentionally NOT included - it interferes with
# Tailscale's routing table management. We use proto='none' instead.
COPY src/ /tmp/files/

# --- apk packaging (A2, RFC §3/§4.1) -------------------------------------
# Placed textually BEFORE the `ipk` stage so that a default `docker build`
# (no --target, as build.sh uses) still resolves to the `ipk` stage as its
# final image, byte-for-byte identical to before this stage existed --
# `ipk` does not depend on `apk`, so a dependency-aware builder never even
# builds this stage unless explicitly targeted (`--target apk`, as
# build-apk.sh / tests/apk/mkpkg.sh do).
FROM build AS apk

ARG TAILSCALE_VERSION
ARG OPENWRT_ARCH
ARG PKG_RELEASE

# $PKGROOT build root (RFC §4.1): `files/` (= $ADIR) is the on-device
# payload ONLY -- no CONTROL/, no maintainer scripts -- and `scripts/` is a
# SIBLING directory, never nested under files/, so `--files "$ADIR"` cannot
# payload-ify the maintainer scripts regardless of `mkpkg` behavior.
WORKDIR /pkgroot
RUN mkdir -p files/usr/sbin \
    files/usr/bin \
    files/etc/init.d \
    files/etc/config \
    files/www/luci-static/resources/protocol \
    files/lib/apk/packages \
    scripts

# Copy binary
RUN cp /build/tailscaled files/usr/sbin/tailscaled && \
    chmod 755 files/usr/sbin/tailscaled

# Same payload the ipk build assembles (RFC §4.1) -- reuse verbatim.
RUN cp /tmp/files/tailscale.init files/etc/init.d/tailscale && \
    cp /tmp/files/tailscale.config files/etc/config/tailscale && \
    cp /tmp/files/tailscale-wrapper.sh files/usr/bin/tailscale && \
    cp /tmp/files/tailscale-killswitch.sh files/usr/sbin/tailscale-killswitch && \
    cp /tmp/files/tailscale-killswitch-boot.sh files/usr/sbin/tailscale-killswitch-boot && \
    cp /tmp/files/tailscale-exitnode.sh files/usr/sbin/tailscale-exitnode && \
    cp /tmp/files/tailscale-setup.sh files/usr/sbin/tailscale-setup && \
    cp /tmp/files/luci-protocol-tailscale.js files/www/luci-static/resources/protocol/tailscale.js && \
    chmod 755 files/etc/init.d/tailscale && \
    chmod 600 files/etc/config/tailscale && \
    chmod 755 files/usr/bin/tailscale && \
    chmod 755 files/usr/sbin/tailscale-killswitch && \
    chmod 755 files/usr/sbin/tailscale-killswitch-boot && \
    chmod 755 files/usr/sbin/tailscale-exitnode && \
    chmod 755 files/usr/sbin/tailscale-setup && \
    chmod 644 files/www/luci-static/resources/protocol/tailscale.js

# Conffiles list staged INSIDE files/ at apk's magic path (RFC §4.1/§3).
RUN echo "/etc/config/tailscale" > files/lib/apk/packages/tailscale.conffiles

# Maintainer scripts as SIBLINGS of files/ (never under $ADIR). Reuse
# src/tailscale.{postinst,prerm,postrm} *logic* verbatim, renamed to apk's
# lifecycle hook names (RFC §4.1). The IPKG_INSTROOT guard is slice A3a --
# used as-is, unguarded, for now.
RUN cp /tmp/files/tailscale.postinst scripts/post-install && \
    cp /tmp/files/tailscale.prerm scripts/pre-deinstall && \
    cp /tmp/files/tailscale.postrm scripts/post-deinstall && \
    chmod 755 scripts/post-install scripts/pre-deinstall scripts/post-deinstall

# Build the .apk (RFC §3 canonical recipe). SOURCE_DATE_EPOCH is the source
# tarball's mtime (GitHub sets archive mtimes to the tagged commit time),
# NOT `git log` (no .git in this build context) and NOT 0 (1970 on-device
# mtimes are indistinguishable from an unsynced RTC). fakeroot is redundant
# here (A1: mkpkg records nobody:nobody regardless of live-FS ownership).
# Version maps ${TAILSCALE_VERSION}-${PKG_RELEASE} -> ${TAILSCALE_VERSION}-r${PKG_RELEASE}.
# Output path is arch-namespaced (arch in the PATH, not the filename).
RUN SOURCE_DATE_EPOCH="$(stat -c %Y /build/tailscale.tar.gz)" && \
    echo "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH} (from /build/tailscale.tar.gz mtime)" && \
    APK_VERSION="${TAILSCALE_VERSION}-r${PKG_RELEASE}" && \
    mkdir -p "/out/${OPENWRT_ARCH}" && \
    SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH}" apk mkpkg \
      --info "name:tailscale" \
      --info "version:${APK_VERSION}" \
      --info "arch:${OPENWRT_ARCH}" \
      --info "description:Tailscale VPN client for OpenWrt" \
      --info "license:BSD-3-Clause" \
      --info "maintainer:Community Build" \
      --info "depends:kmod-tun ca-bundle ip-full conntrack" \
      --files "/pkgroot/files" \
      --script "post-install:/pkgroot/scripts/post-install" \
      --script "pre-deinstall:/pkgroot/scripts/pre-deinstall" \
      --script "post-deinstall:/pkgroot/scripts/post-deinstall" \
      --output "/out/${OPENWRT_ARCH}/tailscale-${APK_VERSION}.apk"

# Debug: show what went into files/ (= $ADIR; must contain no CONTROL/, no
# scripts/) and the built .apk.
RUN echo "=== apk payload (files/) contents ===" && \
    find /pkgroot/files -type f | sort && \
    echo "=== apk build-only siblings (NOT shipped) ===" && \
    find /pkgroot/scripts -type f | sort && \
    echo "=== built .apk ===" && \
    ls -lh /out/*/*.apk

# --- ipk packaging (existing path, unchanged) ---------------------------
FROM build AS ipk

ARG TAILSCALE_VERSION
ARG OPENWRT_ARCH
ARG PKG_RELEASE

# Create IPK package structure
WORKDIR /ipk
RUN mkdir -p usr/sbin \
    usr/bin \
    etc/init.d \
    etc/config \
    www/luci-static/resources/protocol \
    CONTROL

# Copy binary
RUN cp /build/tailscaled usr/sbin/ && \
    chmod 755 usr/sbin/tailscaled

RUN cp /tmp/files/tailscale.init etc/init.d/tailscale && \
    cp /tmp/files/tailscale.config etc/config/tailscale && \
    cp /tmp/files/tailscale-wrapper.sh usr/bin/tailscale && \
    cp /tmp/files/tailscale-killswitch.sh usr/sbin/tailscale-killswitch && \
    cp /tmp/files/tailscale-killswitch-boot.sh usr/sbin/tailscale-killswitch-boot && \
    cp /tmp/files/tailscale-exitnode.sh usr/sbin/tailscale-exitnode && \
    cp /tmp/files/tailscale-setup.sh usr/sbin/tailscale-setup && \
    cp /tmp/files/luci-protocol-tailscale.js www/luci-static/resources/protocol/tailscale.js

RUN chmod 755 etc/init.d/tailscale && \
    chmod 600 etc/config/tailscale && \
    chmod 755 usr/bin/tailscale && \
    chmod 755 usr/sbin/tailscale-killswitch && \
    chmod 755 usr/sbin/tailscale-killswitch-boot && \
    chmod 755 usr/sbin/tailscale-exitnode && \
    chmod 755 usr/sbin/tailscale-setup && \
    chmod 644 www/luci-static/resources/protocol/tailscale.js

# Create control file
RUN cat > CONTROL/control <<EOF
Package: tailscale
Version: ${TAILSCALE_VERSION}-${PKG_RELEASE}
Architecture: ${OPENWRT_ARCH}
Maintainer: Community Build
Section: net
Priority: optional
Depends: kmod-tun, ca-bundle, ip-full, conntrack
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

# Copy package control scripts
RUN cp /tmp/files/tailscale.postinst CONTROL/postinst && \
    cp /tmp/files/tailscale.prerm CONTROL/prerm && \
    cp /tmp/files/tailscale.postrm CONTROL/postrm && \
    chmod 755 CONTROL/postinst CONTROL/prerm CONTROL/postrm

# Debug: Show directory structure
RUN echo "=== Package contents ===" && \
    find /ipk -type f | sort && \
    echo "=== Control files ===" && \
    cat /ipk/CONTROL/control

# Build the IPK
RUN opkg-build /ipk /tmp && \
    mv /tmp/tailscale_${TAILSCALE_VERSION}-${PKG_RELEASE}_${OPENWRT_ARCH}.ipk \
       /tailscale_${TAILSCALE_VERSION}_${OPENWRT_ARCH}.ipk

# Copy raw binary for GL.iNet installs (no IPK, just the binary)
RUN cp /build/tailscaled /tailscaled_${OPENWRT_ARCH}

# Final output location
# Extract IPK: docker run --rm <image> cat /tailscale_*.ipk > package.ipk
# Extract binary: docker run --rm <image> cat /tailscaled_<arch> > tailscaled
