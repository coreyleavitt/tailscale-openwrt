#!/bin/sh
# scripts/apk-resolve-smoke.sh
#
# FU2 (post-527e826 filename-regression follow-up): a smoke install that
# proves a package resolves out of an apk FEED BY NAME
# (`apk add <pkgname>`, apk-tools deriving the fetch URL itself from the
# index's <pkgname>-<pkgver>.apk entry), never by a direct .apk file path
# (`apk add ./tailscale.apk`, which tests/apk/install.sh does and is
# provably blind to a feed filename/index mismatch -- see that script's own
# header and the 527e826 incident this whole follow-up responds to: the
# normal publish path published the arch-suffixed build-artifact basename
# instead of the apk-resolved <pkgname>-<pkgver>.apk, so the LIVE feed
# 404'd on a real `apk add tailscale` while every existing CI install check
# stayed green, because none of them ever resolved by name against the
# published tree).
#
# Deliberately dependency-free of docker/qemu: apk-tools operates on a
# plain on-disk `--root` tree, no container or qemu-user emulation
# required, so this runs on any NATIVE arch the apk-tools binary itself was
# built for (this repo pins apk-tools 3.0.2/x86_64 -- see
# tests/apk/lib.sh's extract_apk_tools_binary) without needing a foreign-
# arch rootfs at all. That's why this is wired as a native (x86_64/amd64)
# smoke check, not a per-arch matrix job -- proving "does resolution-by-
# name work against this feed" needs no arch-specific payload execution,
# only apk-tools' own solver/fetch logic, which is arch-agnostic.
#
# Empirically-confirmed apk-tools 3.0.2 bootstrap requirement (there is no
# `--initdb` flag in this version -- that's a v2-era concept): a bare `apk
# add --root <empty-dir>` fails "Unable to read database" until
# etc/apk/world (empty -- no prior constraints) and lib/apk/db/ both
# pre-exist; this script creates exactly that minimal shape itself, no
# base-image/container needed.
#
# The real tailscale package declares real OpenWrt-repo dependencies
# (kmod-tun, ca-bundle, ip-full, conntrack -- scripts/package-apk.sh's own
# `--info depends:...` line) that a bare scratch root has no repository for
# (unlike tests/apk/install.sh's container-based install, which starts
# from a real OpenWrt rootfs image that already ships some of these). Each
# `--stub-dep NAME` builds a tiny empty local package for NAME (tagged with
# ARCH) and adds it as an additional `-X` repository, so a real dependency
# set resolves without needing a live OpenWrt package mirror -- this proves
# resolution of THIS repo's own feed by name; it is not re-proving that
# kmod-tun etc. themselves install correctly (out of scope, already
# covered by tests/apk/install.sh's real-rootfs coverage).
#
# Usage:
#   apk-resolve-smoke.sh <feed-base> <arch> [--pkgname NAME]
#       [--expect-version VER] [--allow-untrusted | --pubkey PATH]
#       [--keyname NAME] [--stub-dep NAME]...
#
# <feed-base> may be an http(s):// URL (e.g. https://apk.leavitt.dev/apk/
# x86_64, the live production feed) or a local directory path (e.g. a
# freshly assembled pages-root/apk/<arch>, or a `python3 -m http.server`
# base URL for a hermetic hop-through-HTTP test) -- either way,
# `<feed-base>/packages.adb` is what gets passed to apk-tools' own
# -X/--repository flag (this repo's feed layout is flat per-arch: no
# further nesting under packages.adb), so `apk add <pkgname>` resolves via
# the SAME mechanism a real device's `apk add tailscale` uses.
#
# Overridable via environment:
#   APK_BIN   path to the apk-tools binary to use (default: `apk` on PATH
#             -- CI/tests point this at the pinned host binary extracted
#             by tests/apk/lib.sh's extract_apk_tools_binary)

set -eu

die() {
    echo "apk-resolve-smoke.sh: $1" >&2
    exit 1
}

APK_BIN="${APK_BIN:-apk}"

[ $# -ge 2 ] || die "usage: apk-resolve-smoke.sh <feed-base> <arch> [--pkgname NAME] [--expect-version VER] [--allow-untrusted | --pubkey PATH] [--keyname NAME] [--stub-dep NAME]..."
FEED_BASE="$1"; ARCH="$2"; shift 2

PKGNAME="tailscale"
EXPECT_VERSION=""
ALLOW_UNTRUSTED=0
PUBKEY_PATH=""
KEYNAME="tailscale.pem"
STUB_DEPS=""

while [ $# -gt 0 ]; do
    case "$1" in
        --pkgname) PKGNAME="$2"; shift 2 ;;
        --expect-version) EXPECT_VERSION="$2"; shift 2 ;;
        --allow-untrusted) ALLOW_UNTRUSTED=1; shift ;;
        --pubkey) PUBKEY_PATH="$2"; shift 2 ;;
        --keyname) KEYNAME="$2"; shift 2 ;;
        --stub-dep) STUB_DEPS="${STUB_DEPS}$2 "; shift 2 ;;
        *) die "unknown argument '$1'" ;;
    esac
done

command -v "${APK_BIN}" >/dev/null 2>&1 \
    || die "'${APK_BIN}' (APK_BIN) not found on PATH -- extract the pinned host apk-tools binary first (see tests/apk/lib.sh's extract_apk_tools_binary)"

if [ "${ALLOW_UNTRUSTED}" -eq 0 ] && [ -z "${PUBKEY_PATH}" ]; then
    die "must pass either --allow-untrusted or --pubkey <path> -- real signed-feed trust needs the committed EC pubkey (prefer --pubkey; --allow-untrusted only when wiring real trust is out of proportion)"
fi
if [ "${ALLOW_UNTRUSTED}" -eq 1 ] && [ -n "${PUBKEY_PATH}" ]; then
    die "--allow-untrusted and --pubkey are mutually exclusive"
fi
if [ -n "${PUBKEY_PATH}" ] && [ ! -f "${PUBKEY_PATH}" ]; then
    die "--pubkey path not found: ${PUBKEY_PATH}"
fi

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

ROOT="${WORK}/root"
mkdir -p "${ROOT}/lib/apk/db" "${ROOT}/etc/apk"
echo "${ARCH}" > "${ROOT}/etc/apk/arch"
: > "${ROOT}/etc/apk/world"

TRUST_ARGS=""
if [ -n "${PUBKEY_PATH}" ]; then
    mkdir -p "${ROOT}/etc/apk/keys"
    cp "${PUBKEY_PATH}" "${ROOT}/etc/apk/keys/${KEYNAME}"
else
    TRUST_ARGS="--allow-untrusted"
fi

# Build the (optional) local stub-dep repo -- one combined index covering
# every requested --stub-dep name, each an empty package tagged with ARCH
# (mirrors tests/apk/install.sh's/sign-verify.sh's already-proven stub-dep
# trick, generalized to a bare root that has no base image to inherit any
# of them from).
REPO_ARGS="-X ${FEED_BASE%/}/packages.adb"
if [ -n "${STUB_DEPS}" ]; then
    STUB_DIR="${WORK}/stubs"
    STUB_EMPTY="${WORK}/stub-empty"
    mkdir -p "${STUB_DIR}" "${STUB_EMPTY}"
    for _dep in ${STUB_DEPS}; do
        "${APK_BIN}" mkpkg --allow-untrusted \
            --info "name:${_dep}" --info "version:1-r1" --info "arch:${ARCH}" \
            --files "${STUB_EMPTY}" --output "${STUB_DIR}/${_dep}-1-r1.apk" >/dev/null
    done
    "${APK_BIN}" mkndx --allow-untrusted --compression none \
        --output "${STUB_DIR}/packages.adb" "${STUB_DIR}"/*.apk >/dev/null
    echo "apk-resolve-smoke.sh: built local stub-dep repo for: ${STUB_DEPS}(these are NOT what this smoke test is proving -- only ${PKGNAME}'s own feed resolution is)"
    REPO_ARGS="${REPO_ARGS} -X ${STUB_DIR}/packages.adb"
fi

INDEX_URL="${FEED_BASE%/}/packages.adb"
echo "apk-resolve-smoke.sh: SMOKE TEST ONLY (one native arch, not full coverage) -- apk add --root <scratch> ${TRUST_ARGS} ${REPO_ARGS} ${PKGNAME} (arch=${ARCH})"

# --scripts=no: this smoke test proves REPO-NAME RESOLUTION + on-disk
# install (right filename resolved, right bytes land, right version
# recorded) -- it deliberately does NOT run the package's post-install/
# pre-remove maintainer scripts, which assume a real OpenWrt runtime (uci,
# procd, /etc/init.d/*) that a bare `--root` scratch tree never has. That
# behavior is already covered on its own terms by tests/apk/install.sh
# (real rootfs, real script execution) and tests/apk/instroot.sh (the
# maintainer scripts' own install-root redirection guard) -- re-proving it
# here would conflate two orthogonal concerns and make this smoke test
# fail for reasons that have nothing to do with the 527e826 filename-
# resolution regression it exists to catch.
if ! OUT=$("${APK_BIN}" add --root "${ROOT}" --scripts=no ${TRUST_ARGS} ${REPO_ARGS} "${PKGNAME}" 2>&1); then
    echo "${OUT}" >&2
    die "'apk add ${PKGNAME}' FAILED via repo-name resolution against ${INDEX_URL} -- this is the load-bearing check (catches exactly the class of feed filename/index mismatch a direct-file-path install, e.g. tests/apk/install.sh's 'apk add ./tailscale.apk', can never see)"
fi
echo "${OUT}"

INSTALLED_LINE=$("${APK_BIN}" list --root "${ROOT}" --installed "${PKGNAME}" 2>/dev/null | grep "^${PKGNAME}-" || true)
[ -n "${INSTALLED_LINE}" ] || die "apk add reported success but '${PKGNAME}' is not in the installed list afterward"

INSTALLED_VERSION=$(printf '%s\n' "${INSTALLED_LINE}" | sed -n "s/^${PKGNAME}-\([^ ]*\) .*/\1/p")
[ -n "${INSTALLED_VERSION}" ] || die "could not parse installed version out of: ${INSTALLED_LINE}"

echo "OK: ${PKGNAME} resolved BY NAME against ${INDEX_URL} and installed, version=${INSTALLED_VERSION}"

if [ -n "${EXPECT_VERSION}" ]; then
    [ "${INSTALLED_VERSION}" = "${EXPECT_VERSION}" ] \
        || die "installed version '${INSTALLED_VERSION}' does not match --expect-version '${EXPECT_VERSION}'"
    echo "OK: installed version matches --expect-version (${EXPECT_VERSION})"
fi
