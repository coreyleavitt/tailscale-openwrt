#!/bin/sh
# tests/apk/dockerfile-mirror-hardening.sh
#
# Guards the Tumbleweed mirror-flake hardening in
# tailscale-package/Dockerfile against silent reversion. The build image is
# based on openSUSE Tumbleweed, whose download.opensuse.org MirrorCache
# redirector routes to mirrors that 404 freshly-published RPMs for *hours*
# after a new snapshot lands -- this was failing ~1-in-3 of our CI builds
# (see systemd/mkosi#4365 for the same failure class). Two structural fixes
# were applied and this test asserts both are still present:
#
#   1. SNAPSHOT PIN: a `tumbleweed-pinned` base stage repoints the oss/non-oss
#      repos to the frozen, fully-propagated `history/<snapshot>/` tree
#      (second-to-last snapshot, re-resolved each build so it self-advances --
#      NOT a Go version pin) and BOTH heavy stages (apk-tools, build) derive
#      from it. A revert to `FROM ...tumbleweed:latest` in either stage brings
#      the flake back.
#   2. aria2 FETCHES: the large downloads (the ~267MB OpenWrt SDK tarball and
#      the Tailscale source tarball) use aria2c -- multi-connection with
#      built-in retry/resume -- rather than a bare `curl` that does not retry
#      TLS-layer errors (`curl (35) unexpected eof`).
#
# Pure grep/sh, no docker build -- mirroring dockerfile-goarch-drift.sh's
# hermetic style (host-apk.sh already exercises the pin+aria2 for real by
# building the apk-tools stage end-to-end).
#
# Usage: sh tests/apk/dockerfile-mirror-hardening.sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
DOCKERFILE="${REPO_ROOT}/tailscale-package/Dockerfile"

# shellcheck source=tests/apk/lib.sh
. "${SCRIPT_DIR}/lib.sh"

if [ ! -f "${DOCKERFILE}" ]; then
    log_fail "tailscale-package/Dockerfile not found at ${DOCKERFILE}"
    harness_finish "tests/apk/dockerfile-mirror-hardening.sh"
    exit "${FAIL}"
fi

DF=$(cat "${DOCKERFILE}")

echo "=== snapshot pin: a tumbleweed-pinned base stage exists ==="

assert_contains "a tumbleweed-pinned stage is declared" \
    "${DF}" "AS tumbleweed-pinned"

# The pin must resolve the snapshot dynamically (self-advancing) and rewrite
# the repo URLs to the frozen history/ tree -- assert both the resolution and
# the rewrite are present, not a single hardcoded snapshot literal.
assert_contains "the pin resolves the snapshot from history/list" \
    "${DF}" "download.opensuse.org/history/list"
assert_contains "the pin rewrites repos to the history/ snapshot tree" \
    "${DF}" "download.opensuse.org/history/"

echo

echo "=== snapshot pin: both heavy stages derive from tumbleweed-pinned ==="

# The failure mode this guards: a stage reverted to pulling the rolling
# `tumbleweed:latest` directly bypasses the pin and rides the un-propagated
# bleeding edge again. Every `AS apk-tools` / `AS build` stage header must
# derive FROM tumbleweed-pinned.
for _stage in apk-tools build; do
    _from=$(grep -E "AS ${_stage}\$" "${DOCKERFILE}" || true)
    if [ -z "${_from}" ]; then
        log_fail "no 'FROM ... AS ${_stage}' stage found in Dockerfile"
        continue
    fi
    assert_contains "stage '${_stage}' derives from the pinned base" \
        "${_from}" "FROM tumbleweed-pinned AS ${_stage}"
done

# Belt-and-suspenders: no build stage should reach for the rolling image
# directly. The ONLY permitted `tumbleweed:latest` reference is the
# tumbleweed-pinned base stage's own FROM.
LATEST_REFS=$(grep -cE "FROM registry.opensuse.org/opensuse/tumbleweed:latest" "${DOCKERFILE}" || true)
assert_eq "exactly one direct tumbleweed:latest FROM (the pinned base stage itself)" \
    "1" "${LATEST_REFS}"

echo

echo "=== aria2 for the large downloads ==="

# The SDK tarball and the Tailscale source tarball are the two large fetches;
# both must go through aria2c (retry/resume), and the SDK's integrity is
# checksum-verified during the download.
assert_contains "the OpenWrt SDK is fetched with aria2c" \
    "${DF}" "aria2c"
assert_contains "the SDK download is checksum-verified in-flight" \
    "${DF}" 'checksum="sha-256=${OPENWRT_SDK_SHA256}"'

# The real regression to guard: reverting either large fetch back to a bare
# curl that does not retry TLS-layer errors. Assert the pre-hardening curl
# forms are gone.
assert_not_contains "the SDK fetch is not a bare curl" \
    "${DF}" "curl -fsSL -o /tmp/openwrt-sdk.tar.zst"
assert_not_contains "the Tailscale source fetch is not a bare curl" \
    "${DF}" 'curl -L "https://github.com/tailscale/tailscale/archive'

# And aria2 must actually be installed (as a package, not just referenced) in
# both stages that use it: the apk-tools stage lists it inline before curl,
# the build stage lists it as its own backslash-continued line.
assert_contains "aria2 is an installed dep in the apk-tools stage" \
    "${DF}" "install -y aria2 curl tar zstd"
assert_contains "aria2 is an installed dep in the build stage" \
    "${DF}" "aria2 \\"

echo

harness_finish "tests/apk/dockerfile-mirror-hardening.sh"
