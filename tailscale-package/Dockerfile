# Dockerfile for building Tailscale IPK packages for OpenWrt
# Single-stage build using Tumbleweed for Go compilation, UPX compression, and packaging
#
# Build context requirement (RFC docs/rfc-apk-arch-coverage.md §5.1/S3): the
# `ipk` stage's on-device payload now comes from the repo-root
# scripts/stage-payload.sh (the single shared definition also used by the
# host-side scripts/package-apk.sh) rather than an inline duplicate. That
# script lives outside this Dockerfile's own build context
# (tailscale-package/), so every `docker build` invocation that reaches the
# `ipk` stage (default target, or `--target ipk`) MUST pass an additional
# named build context pointing at it:
#   --build-context scripts=<repo-root>/scripts
# (Docker 23+/BuildKit; `docker build` defaults to the buildx/BuildKit
# builder). Omitting it fails the build at the `COPY --from=scripts` step.
# See tailscale-package/build.sh, .github/workflows/build-tailscale.yaml's
# build-ipk job, tests/apk/ipk-matrix.sh, tests/apk/upgrade-downgrade.sh for
# the flag in place. Stages that don't reach `ipk` (`build`/`apk-tools`) are
# unaffected. (The `apk` stage this note used to also list was DELETED in S4
# -- apk packaging is host-side now, see the S4 note further down.)
#
# Build arguments:
#   TAILSCALE_VERSION - Tailscale version to build (e.g., 1.92.2)
#   OPENWRT_ARCH      - OpenWrt architecture (mips_24kc or aarch64_cortex-a53)
#   PKG_RELEASE       - Package release number (default: 1)
#   GOARCH            - Go architecture (e.g. "arm64", "mips", "amd64");
#                       REQUIRED, sourced from arches.json's per-arch goarch
#                       field (RFC docs/rfc-apk-arch-coverage.md §5.1/S2).
#                       No name-based fallback -- the `build` stage
#                       hard-fails if this is empty or not a known Go
#                       GOARCH value.
#   GOARM             - Go ARM float ABI (e.g. "5" for softfloat, "7" for
#                       hard-float); from arches.json's per-arch goarm
#                       field. Only meaningful when GOARCH=arm.
#   GOMIPS            - Go MIPS float ABI (e.g. "softfloat"|"hardfloat");
#                       from arches.json's gomips field. REQUIRED (hard-fail)
#                       when GOARCH is mips/mipsle -- Go's silent default is
#                       hardfloat, which SIGILLs on softfloat MIPS silicon.
#   GOMIPS64          - Go MIPS64 float ABI, from arches.json's gomips64
#                       field. REQUIRED (hard-fail) when GOARCH is
#                       mips64/mips64le, same reasoning as GOMIPS above.
#   GO386             - Go 386 float ABI (e.g. "sse2"|"softfloat"), from
#                       arches.json's go386 field. Only meaningful when
#                       GOARCH=386.

ARG TAILSCALE_VERSION=1.92.2
ARG OPENWRT_ARCH=mips_24kc
ARG PKG_RELEASE=1
ARG SKIP_UPX=0
ARG GLINET_VARIANT=0
# GOARCH/GOARM/GOMIPS/GOMIPS64/GO386: the explicit build tuple, sourced from
# arches.json's per-arch fields by the caller (build-apk.sh/build.sh, or the
# CI workflow's matrix.arch.* fields) and passed as --build-arg. Docker
# silently IGNORES a --build-arg for an ARG that isn't declared here, so
# these declarations are load-bearing -- see the `build` stage below, which
# hard-fails rather than guessing when GOARCH is missing/unrecognized.
ARG GOARCH=
ARG GOARM=
ARG GOMIPS=
ARG GOMIPS64=
ARG GO386=

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
ARG GOARCH
ARG GOARM
ARG GOMIPS
ARG GOMIPS64
ARG GO386

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
# tailscale.tar.gz is intentionally kept (not rm'd) -- callers that need a
# SOURCE_DATE_EPOCH (host-side scripts/package-apk.sh, via `docker run
# --entrypoint stat ... -c %Y /build/tailscale.tar.gz`, S4) read its mtime
# (RFC §3: GitHub sets archive mtimes to the tagged commit time, so this is
# stable across re-runs of the same tailscale_version, unlike `git log`
# against this repo's own HEAD -- and there is no .git in this build context
# anyway).
RUN curl -L "https://github.com/tailscale/tailscale/archive/refs/tags/v${TAILSCALE_VERSION}.tar.gz" -o tailscale.tar.gz && \
    tar -xzf tailscale.tar.gz && \
    mv tailscale-${TAILSCALE_VERSION} tailscale

# Build Tailscale binary with size optimizations
# GOTOOLCHAIN=auto downloads whatever Go version Tailscale requires
#
# GOARCH/GOARM/GOMIPS/GOMIPS64/GO386 are explicit build-args (see the ARG
# declarations above), sourced from arches.json's per-arch build tuple by
# the caller (build-apk.sh/build.sh, or the CI workflow's matrix.arch.*
# fields) -- see scripts/families.sh (RFC docs/rfc-apk-arch-coverage.md
# §5.1/§5.2). There is deliberately NO name-based derivation from
# OPENWRT_ARCH any more: this stage used to derive GOARCH by a string-`case`
# on OPENWRT_ARCH with a `*) -> mips` default, which silently mis-built
# every arch outside aarch64*/arm_cortex*/mipsel* (x86_64, riscv64,
# loong64, mips64, i386, arm1176jzf-s all fell through to 32-bit MIPS).
#
# The validation below hard-fails the build instead of guessing: an empty
# or unrecognized GOARCH aborts loudly, and a MIPS/MIPS64 GOARCH with its
# float ABI left unset also aborts loudly -- Go's silent default there is
# hardfloat, which SIGILLs on softfloat MIPS/MIPS64 silicon (the same class
# of live bug fixed for arm_cortex-a7, see §9).
# GOARCH_VOCAB_CANONICAL (M6 code-review finding drift-guard anchor): this
# exact vocabulary is ALSO hard-fail-guarded, independently, inside
# scripts/families.sh's cmd_validate (it runs host-side, outside any
# container, so it cannot exec into this build stage to share a runtime
# function -- see that script's own matching GOARCH_VOCAB_CANONICAL marker
# comment). tests/apk/dockerfile-goarch-drift.sh greps the first case-arm
# line (`word|word|...) ;;` shape) after EACH marker in both files and
# asserts the two pipe-delimited vocabularies are set-equal -- so a GOARCH
# added here and forgotten there (or vice versa) fails CI instead of
# silently diverging.
WORKDIR /build/tailscale
RUN case "${GOARCH}" in \
      arm64|arm|mips|mipsle|mips64|mips64le|386|amd64|riscv64|loong64) ;; \
      *) \
        echo "ERROR: GOARCH='${GOARCH}' is empty or not a recognized Go GOARCH (expected one of: arm64 arm mips mipsle mips64 mips64le 386 amd64 riscv64 loong64). GOARCH must be passed explicitly via --build-arg, sourced from arches.json's goarch field -- there is no OPENWRT_ARCH name-based fallback." >&2; \
        exit 1 ;; \
    esac && \
    case "${GOARCH}" in \
      mips|mipsle) \
        if [ -z "${GOMIPS}" ]; then \
          echo "ERROR: GOARCH=${GOARCH} requires GOMIPS to be set explicitly (softfloat|hardfloat) -- Go silently defaults to hardfloat, which SIGILLs on softfloat MIPS silicon. Pass --build-arg GOMIPS=, sourced from arches.json's gomips field." >&2; \
          exit 1; \
        fi ;; \
      mips64|mips64le) \
        if [ -z "${GOMIPS64}" ]; then \
          echo "ERROR: GOARCH=${GOARCH} requires GOMIPS64 to be set explicitly (softfloat|hardfloat) -- Go silently defaults to hardfloat, which SIGILLs on softfloat MIPS64 silicon. Pass --build-arg GOMIPS64=, sourced from arches.json's gomips64 field." >&2; \
          exit 1; \
        fi ;; \
    esac && \
    echo "Building for GOARCH=${GOARCH} GOARM=${GOARM} GOMIPS=${GOMIPS} GOMIPS64=${GOMIPS64} GO386=${GO386}" && \
    GOTOOLCHAIN=auto \
    CGO_ENABLED=0 \
    GOOS=linux \
    GOARCH=${GOARCH} \
    GOARM=${GOARM} \
    GOMIPS=${GOMIPS} \
    GOMIPS64=${GOMIPS64} \
    GO386=${GO386} \
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

# Payload sources, shared by the ipk stage below (and, host-side, by
# scripts/package-apk.sh via scripts/stage-payload.sh).
# Note: netifd protocol handler intentionally NOT included - it interferes with
# Tailscale's routing table management. We use proto='none' instead.
COPY src/ /tmp/files/

# --- apk packaging -- REMOVED (RFC docs/rfc-apk-arch-coverage.md §5.1/S4) -
# The `apk` Dockerfile stage (`FROM build AS apk`) that used to live here was
# DELETED this slice: apk packaging is now a host-side step
# (scripts/package-apk.sh, wrapping the same `apk mkpkg` recipe over
# scripts/stage-payload.sh's shared on-device tree), never a second Docker
# build. Compiling stays per-family (`docker build --target build`, this
# stage); packaging runs per-arch on the host afterward, once per arch in a
# family, reusing the one compiled binary (RFC §5.1/§5.3 "decouple compile
# from packaging"). `docker build --target apk` no longer exists anywhere in
# this repo -- every former caller (the `build-apk` CI job, `apk-install-verify`,
# tests/apk/{mkpkg,apk-matrix,install,sign-verify,install-dispatch,
# upgrade-downgrade}.sh) was migrated to `--target build` + package-apk.sh.

# --- ipk packaging (S3: on-device tree now sourced from stage-payload.sh) -
FROM build AS ipk

ARG TAILSCALE_VERSION
ARG OPENWRT_ARCH
ARG PKG_RELEASE

# Create IPK package structure
WORKDIR /ipk

# Format-agnostic on-device tree: ONE shared definition (RFC
# docs/rfc-apk-arch-coverage.md §5.1/S3, "one payload source of truth"),
# scripts/stage-payload.sh -- previously this stage duplicated the
# apk stage's own cp+chmod block inline (drift risk between the two
# packaging formats). scripts/ lives at the repo root, outside this
# Dockerfile's own build context (tailscale-package/), so it's brought in
# via a named additional build context rather than a plain COPY -- every
# caller that builds this stage passes `--build-context
# scripts=<repo-root>/scripts` (see build.sh, build-tailscale.yaml's
# build-ipk job, tests/apk/ipk-matrix.sh, tests/apk/upgrade-downgrade.sh).
# CONTROL/ (below) stays format-specific and out of stage-payload.sh.
COPY --from=scripts stage-payload.sh /tmp/stage-payload.sh
RUN mkdir -p CONTROL && \
    sh /tmp/stage-payload.sh /tmp/files /ipk /build/tailscaled

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
