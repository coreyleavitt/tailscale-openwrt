#!/bin/sh
# tests/apk/resolve-install-smoke.sh
#
# FU2 (post-527e826 filename-regression follow-up) test: proves
# scripts/apk-resolve-smoke.sh's REPO-NAME resolution (`apk add tailscale`
# against a configured repository) actually has teeth for exactly the class
# of bug tests/apk/install.sh is blind to -- install.sh's real-rootfs
# install always runs `apk add ... /tailscale.apk` (a direct file path), so
# it never once asks apk-tools to resolve `tailscale` BY NAME out of a
# feed's packages.adb. That's precisely the gap the 527e826 filename-suffix
# regression exploited: the live feed 404'd on `apk add tailscale` while
# every existing CI install check stayed green.
#
# Hermetic (no live network): builds two local trees --
#   - a CORRECTLY published one (de-suffixed <pkgname>-<pkgver>.apk,
#     matching apk-tools' own resolution convention), and
#   - the exact 527e826 shape (arch-suffixed on disk, de-suffixed in the
#     index) --
# serves each via a plain `python3 -m http.server` (mirrors
# tests/apk/feed-publish.sh's own hermetic HTTP pattern), and asserts
# scripts/apk-resolve-smoke.sh PASSES against the correct tree and FAILS
# against the broken one -- proving the resolution mechanism itself (not
# just the assemble-time filename computation tests/apk/publish-feed.sh's
# section 13 already covers) would have caught this regression.
#
# Also covers the smoke script's own bootstrap/arg-handling: real dependency
# resolution (kmod-tun/ca-bundle/ip-full/conntrack, scripts/package-apk.sh's
# own `--info depends:...` line) via the local `--stub-dep` mechanism, and
# --allow-untrusted vs --pubkey mutual exclusivity.
#
# Uses the shared tests/apk/lib.sh harness + its extract_apk_tools_binary
# (the pinned host apk-tools 3.0.2/x86_64 binary -- no docker/qemu payload
# execution needed beyond that one-time extraction, since apk-tools itself
# operates on a bare `--root` tree; see scripts/apk-resolve-smoke.sh's own
# header for why this needs no per-arch rootfs container at all).
#
# Usage: sh tests/apk/resolve-install-smoke.sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
PKG_DIR="${REPO_ROOT}/tailscale-package"
SMOKE_SH="${REPO_ROOT}/scripts/apk-resolve-smoke.sh"

# shellcheck source=tests/apk/lib.sh
. "${SCRIPT_DIR}/lib.sh"

require_cmd docker
require_cmd curl
require_cmd python3

if [ ! -x "${SMOKE_SH}" ] && [ ! -f "${SMOKE_SH}" ]; then
    echo "FAIL: ${SMOKE_SH} not found" >&2
    exit 1
fi

WORKDIR=$(mktemp -d)
SRV_PID=""
cleanup() {
    if [ -n "${SRV_PID}" ]; then kill "${SRV_PID}" >/dev/null 2>&1 || true; fi
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT

echo "=== extracting pinned apk-tools binary ==="
BIN_DIR="${WORKDIR}/bin"
extract_apk_tools_binary "${BIN_DIR}" "${PKG_DIR}"
export APK_BIN="${BIN_DIR}/apk"
"${APK_BIN}" --version >&2

mkdir -p "${WORKDIR}/pkgroot-empty"

ARCH="x86_64"
VERSION="1.98.9-r4"

mk_tree_correct() {
    # mk_tree_correct <dir> -- de-suffixed filename, matching the package's
    # OWN internal name/version (correct feed convention).
    _dir="$1"
    mkdir -p "${_dir}"
    "${APK_BIN}" mkpkg --allow-untrusted --info "name:tailscale" --info "version:${VERSION}" \
        --info "arch:${ARCH}" --info "depends:kmod-tun ca-bundle ip-full conntrack" \
        --files "${WORKDIR}/pkgroot-empty" \
        --output "${_dir}/tailscale-${VERSION}.apk" >/dev/null
    "${APK_BIN}" mkndx --allow-untrusted --compression none --output "${_dir}/packages.adb" "${_dir}"/*.apk >/dev/null
}

mk_tree_arch_suffixed() {
    # mk_tree_arch_suffixed <dir> -- the EXACT 527e826 shape: on-disk file
    # keeps package-apk.sh's arch-suffixed build-artifact name, but the
    # package's internal name/version (what mkndx indexes) is de-suffixed
    # -- so the index resolves `tailscale` to a filename that is NOT
    # present in the tree.
    _dir="$1"
    mkdir -p "${_dir}"
    "${APK_BIN}" mkpkg --allow-untrusted --info "name:tailscale" --info "version:${VERSION}" \
        --info "arch:${ARCH}" --info "depends:kmod-tun ca-bundle ip-full conntrack" \
        --files "${WORKDIR}/pkgroot-empty" \
        --output "${_dir}/tailscale-${VERSION}-${ARCH}.apk" >/dev/null
    "${APK_BIN}" mkndx --allow-untrusted --compression none --output "${_dir}/packages.adb" "${_dir}"/*.apk >/dev/null
}

serve() {
    # serve <dir> <port> -- starts a background http.server rooted at
    # <dir>, waits for it to answer, sets SRV_PID.
    _dir="$1"; _port="$2"
    ( cd "${_dir}" && exec python3 -m http.server "${_port}" >"${WORKDIR}/httpd-${_port}.log" 2>&1 ) &
    SRV_PID=$!
    _i=0
    while [ "${_i}" -lt 40 ]; do
        if curl -fsS -o /dev/null "http://127.0.0.1:${_port}/packages.adb" 2>/dev/null; then return 0; fi
        _i=$((_i + 1)); sleep 0.25
    done
    return 1
}

stop_srv() {
    if [ -n "${SRV_PID}" ]; then kill "${SRV_PID}" >/dev/null 2>&1 || true; fi
    SRV_PID=""
}

# ===========================================================================
# 1. GREEN: correctly-published (de-suffixed) tree resolves + installs by
#    name via `apk add tailscale`
# ===========================================================================
echo "=== 1. correctly-published (de-suffixed) tree: apk add tailscale (repo resolution) succeeds ==="

TREE_GOOD="${WORKDIR}/tree-good"
mk_tree_correct "${TREE_GOOD}"

PORT_GOOD=18601
if ! serve "${TREE_GOOD}" "${PORT_GOOD}"; then
    log_fail "http.server for the correct tree never came up"
fi

RC=0
sh "${SMOKE_SH}" "http://127.0.0.1:${PORT_GOOD}" "${ARCH}" \
    --allow-untrusted --expect-version "${VERSION}" \
    --stub-dep kmod-tun --stub-dep ca-bundle --stub-dep ip-full --stub-dep conntrack \
    >"${WORKDIR}/smoke-good.log" 2>&1 || RC=$?
cat "${WORKDIR}/smoke-good.log"
assert_eq "correct tree: apk-resolve-smoke.sh exits 0 (apk add tailscale resolved + installed by NAME)" "0" "${RC}"
assert_contains "correct tree: reports the resolved-by-name success" \
    "$(cat "${WORKDIR}/smoke-good.log")" "resolved BY NAME"
assert_contains "correct tree: installed version matches" \
    "$(cat "${WORKDIR}/smoke-good.log")" "version matches --expect-version (${VERSION})"

stop_srv

echo

# ===========================================================================
# 2. RED: the 527e826 shape (arch-suffixed on disk, de-suffixed in index)
#    FAILS to resolve by name -- proves this smoke test has teeth for
#    EXACTLY the bug class the incident was.
# ===========================================================================
echo "=== 2. REGRESSION SHAPE (arch-suffixed on disk / de-suffixed in index): apk add tailscale FAILS to resolve ==="

TREE_BAD="${WORKDIR}/tree-bad"
mk_tree_arch_suffixed "${TREE_BAD}"

PORT_BAD=18602
if ! serve "${TREE_BAD}" "${PORT_BAD}"; then
    log_fail "http.server for the arch-suffixed tree never came up"
fi

RC=0
sh "${SMOKE_SH}" "http://127.0.0.1:${PORT_BAD}" "${ARCH}" \
    --allow-untrusted --expect-version "${VERSION}" \
    --stub-dep kmod-tun --stub-dep ca-bundle --stub-dep ip-full --stub-dep conntrack \
    >"${WORKDIR}/smoke-bad.log" 2>&1 || RC=$?
cat "${WORKDIR}/smoke-bad.log"
assert_eq "527e826 shape: apk-resolve-smoke.sh exits NON-ZERO (apk add tailscale could not resolve the de-suffixed name)" "true" \
    "$([ "${RC}" -ne 0 ] && echo true || echo false)"
assert_contains "527e826 shape: names the load-bearing repo-resolution failure" \
    "$(cat "${WORKDIR}/smoke-bad.log")" "FAILED via repo-name resolution"
# Over a real HTTP fetch (unlike a bare local-file-path base), apk-tools
# reports this as a fetch-time 404 ("remote server returned error"), not the
# "package mentioned in index not found" message a purely local-path base
# gives (both are the SAME underlying cause: the index's resolved filename
# is absent from the tree) -- assert the HTTP-shaped message this hermetic
# server-backed test actually produces.
assert_contains "527e826 shape: underlying apk error is the expected fetch-404 shape (index resolved a filename the server doesn't have)" \
    "$(cat "${WORKDIR}/smoke-bad.log")" "remote server returned error"

stop_srv

echo

# ===========================================================================
# 3. arg-handling: --allow-untrusted and --pubkey are mutually exclusive;
#    at least one is required (never silently defaults to untrusted).
# ===========================================================================
echo "=== 3. arg-handling: trust flags ==="

RC=0
sh "${SMOKE_SH}" "http://127.0.0.1:${PORT_GOOD}" "${ARCH}" >"${WORKDIR}/no-trust-flag.log" 2>&1 || RC=$?
assert_eq "neither --allow-untrusted nor --pubkey given: exits non-zero (never silently untrusted)" "true" \
    "$([ "${RC}" -ne 0 ] && echo true || echo false)"
assert_contains "no-trust-flag error names both options" \
    "$(cat "${WORKDIR}/no-trust-flag.log")" "--allow-untrusted or --pubkey"

RC=0
sh "${SMOKE_SH}" "http://127.0.0.1:${PORT_GOOD}" "${ARCH}" --allow-untrusted --pubkey "${WORKDIR}/nonexistent.pem" \
    >"${WORKDIR}/both-trust-flags.log" 2>&1 || RC=$?
assert_eq "both --allow-untrusted and --pubkey given: exits non-zero (mutually exclusive)" "true" \
    "$([ "${RC}" -ne 0 ] && echo true || echo false)"
assert_contains "both-trust-flags error names the conflict" \
    "$(cat "${WORKDIR}/both-trust-flags.log")" "mutually exclusive"

echo

harness_finish "tests/apk/resolve-install-smoke.sh"
