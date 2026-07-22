#!/bin/sh
# scripts/stage-payload.sh
#
# Slice S3 (RFC docs/rfc-apk-arch-coverage.md §5.1, "one payload source of
# truth"): the SINGLE definition of the common, FORMAT-AGNOSTIC on-device
# file tree that both .apk and .ipk ship identically -- tailscaled + the
# init script, UCI config, CLI wrapper, killswitch(+boot), exitnode helper,
# setup helper, LuCI protocol JS, and the sysupgrade keep.d entry -- each at
# its exact on-device path and mode.
#
# This logic used to be duplicated inline in tailscale-package/Dockerfile's
# `apk` stage (its `files/...` cp+chmod block) and `ipk` stage (its
# `usr/...`/`etc/...` cp+chmod block). Moving apk packaging host-side
# (scripts/package-apk.sh) would otherwise create a THIRD independently
# drifting copy -- this script is consumed by both package-apk.sh and the
# Dockerfile `ipk` stage instead (S4 later deletes the dead Dockerfile `apk`
# stage, which is the last remaining inline copy).
#
# Deliberately OUT of scope (each package format adds these itself, never
# staged here):
#   - apk: lib/apk/packages/<name>.conffiles + the maintainer scripts
#     (post-install/pre-deinstall/post-deinstall), which live as SIBLINGS of
#     the staged tree, never nested inside it (RFC §4.1) -- see
#     scripts/package-apk.sh.
#   - ipk: CONTROL/ (control, conffiles, postinst/prerm/postrm) -- see
#     tailscale-package/Dockerfile's `ipk` stage.
#
# Named flags, not positionals (RFC docs/rfc-apk-arch-coverage.md handoff
# L4 code-review finding): three similarly-shaped path args is exactly the
# transposable-positional class of bug scripts/package-apk.sh was already
# redesigned off of (see that script's own "RFC round-2 D-SEV3" header
# note) -- stage-payload.sh mirrors that same named-flag convention here.
#
# Usage:
#   stage-payload.sh --src-dir <dir> --dest-root <dir> --binary <path>
#
#   --src-dir    Directory holding the non-binary on-device source files
#                (tailscale.init, tailscale.config, tailscale-wrapper.sh,
#                tailscale-killswitch.sh, tailscale-killswitch-boot.sh,
#                tailscale-exitnode.sh, tailscale-setup.sh,
#                luci-protocol-tailscale.js, tailscale.keep) -- normally
#                tailscale-package/src.
#   --dest-root  Directory to stage the on-device tree INTO (created if
#                missing, along with every subdirectory needed). Explicit
#                rather than assumed, and CWD-independent -- e.g.
#                $PKGROOT/files for the apk build, /ipk for the ipk build,
#                a plain mktemp dir for package-apk.sh.
#   --binary     Path to the already-built tailscaled binary for this
#                family, staged at usr/sbin/tailscaled (mode 755). Taken as
#                an explicit argument (not a fixed path) because compile
#                (Docker, per-family) and packaging (host-side, per-arch)
#                run in different places and don't share a filesystem
#                convention -- see RFC §5.1.
#
# POSIX sh only (mirrors this repo's other scripts/*.sh -- no bashisms).

set -eu

usage() {
    cat >&2 <<'EOF'
Usage: stage-payload.sh --src-dir <dir> --dest-root <dir> --binary <path>
EOF
}

SRC_DIR=
DEST_ROOT=
BINARY_PATH=

while [ $# -gt 0 ]; do
    case "$1" in
        --src-dir)
            [ $# -ge 2 ] || { echo "stage-payload.sh: --src-dir requires a value" >&2; exit 1; }
            SRC_DIR="$2"; shift 2 ;;
        --dest-root)
            [ $# -ge 2 ] || { echo "stage-payload.sh: --dest-root requires a value" >&2; exit 1; }
            DEST_ROOT="$2"; shift 2 ;;
        --binary)
            [ $# -ge 2 ] || { echo "stage-payload.sh: --binary requires a value" >&2; exit 1; }
            BINARY_PATH="$2"; shift 2 ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "stage-payload.sh: unrecognized argument: $1" >&2
            usage
            exit 1 ;;
    esac
done

if [ -z "${SRC_DIR}" ] || [ -z "${DEST_ROOT}" ] || [ -z "${BINARY_PATH}" ]; then
    echo "stage-payload.sh: --src-dir, --dest-root, and --binary are all required" >&2
    usage
    exit 1
fi

if [ ! -d "${SRC_DIR}" ]; then
    echo "stage-payload.sh: src-dir '${SRC_DIR}' is not a directory" >&2
    exit 1
fi

if [ ! -f "${BINARY_PATH}" ]; then
    echo "stage-payload.sh: binary-path '${BINARY_PATH}' not found" >&2
    exit 1
fi

for _f in tailscale.init tailscale.config tailscale-wrapper.sh \
          tailscale-killswitch.sh tailscale-killswitch-boot.sh \
          tailscale-exitnode.sh tailscale-setup.sh \
          luci-protocol-tailscale.js tailscale.keep; do
    if [ ! -f "${SRC_DIR}/${_f}" ]; then
        echo "stage-payload.sh: missing source file ${SRC_DIR}/${_f}" >&2
        exit 1
    fi
done

mkdir -p \
    "${DEST_ROOT}/usr/sbin" \
    "${DEST_ROOT}/usr/bin" \
    "${DEST_ROOT}/etc/init.d" \
    "${DEST_ROOT}/etc/config" \
    "${DEST_ROOT}/www/luci-static/resources/protocol" \
    "${DEST_ROOT}/lib/upgrade/keep.d"

cp "${BINARY_PATH}" "${DEST_ROOT}/usr/sbin/tailscaled"

cp "${SRC_DIR}/tailscale.init" "${DEST_ROOT}/etc/init.d/tailscale"
cp "${SRC_DIR}/tailscale.config" "${DEST_ROOT}/etc/config/tailscale"
cp "${SRC_DIR}/tailscale-wrapper.sh" "${DEST_ROOT}/usr/bin/tailscale"
cp "${SRC_DIR}/tailscale-killswitch.sh" "${DEST_ROOT}/usr/sbin/tailscale-killswitch"
cp "${SRC_DIR}/tailscale-killswitch-boot.sh" "${DEST_ROOT}/usr/sbin/tailscale-killswitch-boot"
cp "${SRC_DIR}/tailscale-exitnode.sh" "${DEST_ROOT}/usr/sbin/tailscale-exitnode"
cp "${SRC_DIR}/tailscale-setup.sh" "${DEST_ROOT}/usr/sbin/tailscale-setup"
cp "${SRC_DIR}/luci-protocol-tailscale.js" "${DEST_ROOT}/www/luci-static/resources/protocol/tailscale.js"

# Sysupgrade keep-list: tells OpenWrt's sysupgrade to preserve the whole
# /etc/tailscale/ dir (tailscaled.state + derpmap.cached.json) across a
# firmware upgrade -- without it, sysupgrade wipes the node's identity,
# forcing re-auth (and re-approval of subnet routes) on every upgrade.
cp "${SRC_DIR}/tailscale.keep" "${DEST_ROOT}/lib/upgrade/keep.d/tailscale"

chmod 755 "${DEST_ROOT}/usr/sbin/tailscaled"
chmod 755 "${DEST_ROOT}/etc/init.d/tailscale"
chmod 600 "${DEST_ROOT}/etc/config/tailscale"
chmod 755 "${DEST_ROOT}/usr/bin/tailscale"
chmod 755 "${DEST_ROOT}/usr/sbin/tailscale-killswitch"
chmod 755 "${DEST_ROOT}/usr/sbin/tailscale-killswitch-boot"
chmod 755 "${DEST_ROOT}/usr/sbin/tailscale-exitnode"
chmod 755 "${DEST_ROOT}/usr/sbin/tailscale-setup"
chmod 644 "${DEST_ROOT}/www/luci-static/resources/protocol/tailscale.js"
chmod 644 "${DEST_ROOT}/lib/upgrade/keep.d/tailscale"

echo "stage-payload.sh: staged on-device tree at ${DEST_ROOT} (binary: ${BINARY_PATH})"
