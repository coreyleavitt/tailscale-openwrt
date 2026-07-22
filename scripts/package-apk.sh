#!/bin/sh
# scripts/package-apk.sh
#
# Slice S3 (RFC docs/rfc-apk-arch-coverage.md §5.1): host-side apk
# packaging -- NO Docker, no toolchain. Wraps the pinned host apk-tools
# 3.0.2 `apk mkpkg` (extracted from the OpenWrt 25.12.0 SDK, same binary
# tailscale-package/Dockerfile's `apk-tools` stage / tests/apk/lib.sh's
# extract_apk_tools_binary produce) to build one arch's .apk from an
# already-built family tailscaled binary. Binary bytes are identical across
# a family's arches; only .PKGINFO's `arch:` (and the output path) differ
# per invocation, so this is meant to be called once per arch (30x),
# reusing one compiled binary per family (14x) -- see RFC §5.3.
#
# The on-device payload tree is staged by scripts/stage-payload.sh (the
# "one payload source of truth" shared with the Dockerfile `ipk` stage --
# RFC §5.1). This script adds only the apk-specific bits on top:
#   - lib/apk/packages/tailscale.conffiles, staged as a REAL on-device
#     payload file (not an ADB info field -- apk's conffile protection is
#     payload-driven; see tests/apk/mkpkg.sh's Q1 note / upstream
#     include/package-pack.mk).
#   - the three maintainer scripts (post-install/pre-deinstall/
#     post-deinstall), mapped from src/tailscale.{postinst,prerm,postrm} and
#     kept as SIBLINGS of the payload dir passed to `--files` (never nested
#     inside it), mirroring the Dockerfile apk stage's `--script` wiring.
#
# Named flags, not positionals (RFC round-2 D-SEV3): a 30x-invoked script
# with several similarly-shaped string args (version/release/arch) is
# exactly the transposable-positional class of bug the RFC calls out.
#
# Usage:
#   package-apk.sh --binary <path> --arch <name> --version <ver-r<rel>> \
#                  --payload <src-dir> --apk-bin <path> --out <outfile>
#
#   --binary   Path to the already-built family tailscaled binary (static,
#              CGO_ENABLED=0 -- produced by the Dockerfile `build` stage /
#              a CI compile-job artifact, one per family).
#   --arch     The OpenWrt arch string stamped into .PKGINFO's arch: field
#              (arches.json's `name`, e.g. aarch64_cortex-a53).
#   --version  The ALREADY-JOINED "<tailscale-version>-r<pkg-release>"
#              string (e.g. 1.98.9-r2) -- the exact form apk's
#              `--info version:` wants. Computed ONCE by the caller; this
#              script does NOT take version/release as two separate
#              positionals and re-join them (RFC §5.1 -- kills the third
#              independent copy of that string-join, after build-apk.sh and
#              the Dockerfile).
#   --payload  tailscale-package/src (or equivalent): passed straight
#              through to stage-payload.sh as its <src-dir>, and also where
#              this script reads tailscale.postinst/prerm/postrm from.
#   --apk-bin  Path to the pinned host apk-tools 3.0.2 binary (mkpkg/mkndx).
#              Tests obtain this via extract_apk_tools_binary
#              (tests/apk/lib.sh).
#   --out      Output .apk path (parent directory created if missing).
#
# Env:
#   SOURCE_DATE_EPOCH  Honored if already set (passed straight through to
#     `apk mkpkg`, same as the Dockerfile apk stage's
#     `SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH}" apk mkpkg ...`, for a
#     deterministic .PKGINFO timestamp). Defaults to the current time if
#     unset -- NOT deterministic; a caller that needs reproducible output
#     (e.g. a byte-identical comparison against the Dockerfile apk stage)
#     must export SOURCE_DATE_EPOCH itself.
#
# POSIX sh only. Depends on the sibling scripts/stage-payload.sh.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STAGE_PAYLOAD="${SCRIPT_DIR}/stage-payload.sh"

usage() {
    cat >&2 <<'EOF'
Usage: package-apk.sh --binary <path> --arch <name> --version <ver-r<rel>> \
                       --payload <src-dir> --apk-bin <path> --out <outfile>
EOF
}

BINARY=
ARCH=
VERSION=
PAYLOAD=
APK_BIN=
OUT=

while [ $# -gt 0 ]; do
    case "$1" in
        --binary)
            [ $# -ge 2 ] || { echo "package-apk.sh: --binary requires a value" >&2; exit 1; }
            BINARY="$2"; shift 2 ;;
        --arch)
            [ $# -ge 2 ] || { echo "package-apk.sh: --arch requires a value" >&2; exit 1; }
            ARCH="$2"; shift 2 ;;
        --version)
            [ $# -ge 2 ] || { echo "package-apk.sh: --version requires a value" >&2; exit 1; }
            VERSION="$2"; shift 2 ;;
        --payload)
            [ $# -ge 2 ] || { echo "package-apk.sh: --payload requires a value" >&2; exit 1; }
            PAYLOAD="$2"; shift 2 ;;
        --apk-bin)
            [ $# -ge 2 ] || { echo "package-apk.sh: --apk-bin requires a value" >&2; exit 1; }
            APK_BIN="$2"; shift 2 ;;
        --out)
            [ $# -ge 2 ] || { echo "package-apk.sh: --out requires a value" >&2; exit 1; }
            OUT="$2"; shift 2 ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "package-apk.sh: unrecognized argument: $1" >&2
            usage
            exit 1 ;;
    esac
done

if [ -z "${BINARY}" ] || [ -z "${ARCH}" ] || [ -z "${VERSION}" ] || \
   [ -z "${PAYLOAD}" ] || [ -z "${APK_BIN}" ] || [ -z "${OUT}" ]; then
    echo "package-apk.sh: --binary, --arch, --version, --payload, --apk-bin, and --out are all required" >&2
    usage
    exit 1
fi

if [ ! -f "${STAGE_PAYLOAD}" ]; then
    echo "package-apk.sh: ${STAGE_PAYLOAD} not found" >&2
    exit 1
fi
if [ ! -f "${BINARY}" ]; then
    echo "package-apk.sh: --binary '${BINARY}' not found" >&2
    exit 1
fi
if [ ! -x "${APK_BIN}" ]; then
    echo "package-apk.sh: --apk-bin '${APK_BIN}' not found or not executable" >&2
    exit 1
fi
if [ ! -d "${PAYLOAD}" ]; then
    echo "package-apk.sh: --payload '${PAYLOAD}' is not a directory" >&2
    exit 1
fi
for _f in tailscale.postinst tailscale.prerm tailscale.postrm; do
    if [ ! -f "${PAYLOAD}/${_f}" ]; then
        echo "package-apk.sh: missing maintainer-script source ${PAYLOAD}/${_f}" >&2
        exit 1
    fi
done

PKGROOT=$(mktemp -d)
trap 'rm -rf "${PKGROOT}"' EXIT

mkdir -p "${PKGROOT}/scripts"

# Format-agnostic on-device tree: the one shared definition (RFC §5.1).
sh "${STAGE_PAYLOAD}" --src-dir "${PAYLOAD}" --dest-root "${PKGROOT}/files" --binary "${BINARY}"

# apk-specific: conffiles as a real on-device payload file, staged INSIDE
# files/ at apk's magic path (RFC §4.1 / tests/apk/mkpkg.sh's Q1 note).
mkdir -p "${PKGROOT}/files/lib/apk/packages"
echo "/etc/config/tailscale" > "${PKGROOT}/files/lib/apk/packages/tailscale.conffiles"

# apk-specific: maintainer scripts as SIBLINGS of files/ (never nested under
# it), mirroring the Dockerfile apk stage's mapping onto apk's lifecycle
# hook names.
cp "${PAYLOAD}/tailscale.postinst" "${PKGROOT}/scripts/post-install"
cp "${PAYLOAD}/tailscale.prerm" "${PKGROOT}/scripts/pre-deinstall"
cp "${PAYLOAD}/tailscale.postrm" "${PKGROOT}/scripts/post-deinstall"
chmod 755 "${PKGROOT}/scripts/post-install" "${PKGROOT}/scripts/pre-deinstall" "${PKGROOT}/scripts/post-deinstall"

_out_dir=$(dirname -- "${OUT}")
mkdir -p "${_out_dir}"

SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(date +%s)}" \
"${APK_BIN}" mkpkg \
    --info "name:tailscale" \
    --info "version:${VERSION}" \
    --info "arch:${ARCH}" \
    --info "description:Tailscale VPN client for OpenWrt" \
    --info "license:BSD-3-Clause" \
    --info "maintainer:Community Build" \
    --info "depends:kmod-tun ca-bundle ip-full conntrack" \
    --files "${PKGROOT}/files" \
    --script "post-install:${PKGROOT}/scripts/post-install" \
    --script "pre-deinstall:${PKGROOT}/scripts/pre-deinstall" \
    --script "post-deinstall:${PKGROOT}/scripts/post-deinstall" \
    --output "${OUT}"

echo "package-apk.sh: built ${OUT} (name=tailscale version=${VERSION} arch=${ARCH})"
