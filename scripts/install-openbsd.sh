#!/bin/sh
# OpenBSD Tailscale updater (raw openbsd-amd64 release asset)
#
# Replaces the ports/pkg tailscaled (which is pinned per OpenBSD release
# and goes stale between OS upgrades) with the trusted self-built binary
# from this repo's releases, in place at /usr/local/bin. The previous
# binary is kept as tailscaled.prev and restored automatically if the new
# daemon fails its health check -- important on hosts where SSH access IS
# Tailscale SSH, so a bad swap must self-heal without network help.
#
# `pkg_add -u` will clobber the override whenever the port updates; that
# is expected and harmless -- the weekly cron run detects the version
# regression and re-swaps. The CLI is embedded in the daemon binary
# (ts_include_cli), so /usr/local/bin/tailscale becomes a symlink.
#
# Uses base-system tools only: ftp(1) for HTTPS, sha256(1) -C, rcctl(8).
# Verification is HTTPS + sha256 against the release's usign-signed
# SHA256SUMS (no usign on the host; the .sig is kept beside the binary
# for offline audit -- same documented deviation as install-glkvm.sh).
#
# Go openbsd/amd64 binaries link the host's libc at runtime and Go
# supports only the two most recent OpenBSD releases -- keep the host on
# a supported release (sysupgrade) or updates may stop executing; the
# health-check/rollback below turns that failure into a no-op.
#
# Usage:
#   install-openbsd.sh install   # first-time: self-install, cron, update
#   install-openbsd.sh update    # fetch latest if newer, swap, verify
#   install-openbsd.sh revert    # restore tailscaled.prev
#   install-openbsd.sh status

set -eu

REPO="coreyleavitt/tailscale-builds"
ASSET_ARCH="openbsd-amd64"
BIN="/usr/local/bin/tailscaled"
CLI="/usr/local/bin/tailscale"
SELF="/usr/local/sbin/install-openbsd.sh"
CRON_LINE="30 4 * * 0 ${SELF} update >/var/log/tailscale-update.log 2>&1"
API="https://api.github.com/repos/${REPO}/releases/latest"

log() { echo "[obsd-ts] $*"; logger -t obsd-ts "$*" 2>/dev/null || true; }
die() { log "ERROR: $*"; exit 1; }

fetch() { ftp -o "$2" "$1" >/dev/null 2>&1; }

latest_version() {
    fetch "$API" /tmp/ts-latest.json || die "release API fetch failed"
    sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' /tmp/ts-latest.json | head -1
}

running_version() {
    "$CLI" version 2>/dev/null | head -1 || echo "none"
}

backend_state() {
    "$CLI" status --json 2>/dev/null | sed -n 's/.*"BackendState": *"\([^"]*\)".*/\1/p' | head -1
}

ensure_cron() {
    if ! crontab -l 2>/dev/null | grep -q "install-openbsd.sh"; then
        (crontab -l 2>/dev/null; echo "$CRON_LINE") | crontab -
        log "installed weekly update cron"
    fi
}

health_check() {
    want="$1"
    i=0
    while [ $i -lt 18 ]; do
        if [ "$(backend_state)" = "Running" ] && [ "$(running_version)" = "$want" ]; then
            return 0
        fi
        sleep 5
        i=$((i + 1))
    done
    return 1
}

do_update() {
    want="$(latest_version)"
    [ -n "$want" ] || die "could not determine latest release"
    have="$(running_version)"
    if [ "$want" = "$have" ]; then
        log "already at $want"
        ensure_cron
        return 0
    fi
    log "updating $have -> $want"

    tmp="/tmp/ts-update.$$"
    mkdir -p "$tmp"
    trap 'rm -rf "$tmp"' EXIT

    base_url="https://github.com/${REPO}/releases/download/v${want}"
    asset="tailscaled_${want}_${ASSET_ARCH}"
    fetch "$base_url/$asset" "$tmp/tailscaled" || die "binary download failed"
    fetch "$base_url/SHA256SUMS" "$tmp/SHA256SUMS" || die "SHA256SUMS download failed"
    fetch "$base_url/SHA256SUMS.sig" "$tmp/SHA256SUMS.sig" || true

    ( cd "$tmp" && mv tailscaled "$asset" && sha256 -C SHA256SUMS "$asset" ) \
        || die "checksum verification failed for $asset"
    mv "$tmp/$asset" "$tmp/tailscaled"

    chmod 755 "$tmp/tailscaled"
    ver_out="$("$tmp/tailscaled" version 2>/dev/null | head -1)" \
        || die "downloaded binary does not execute on this host (OpenBSD release too old for its Go toolchain?)"
    [ "$ver_out" = "$want" ] || die "binary reports '$ver_out', expected $want"

    [ -x "$BIN" ] && cp -p "$BIN" "${BIN}.prev"
    install -m 755 "$tmp/tailscaled" "$BIN"
    [ -h "$CLI" ] || { [ -e "$CLI" ] && mv "$CLI" "${CLI}.pkg"; }
    ln -sf tailscaled "$CLI"
    cp "$tmp/SHA256SUMS" /usr/local/share/tailscale-SHA256SUMS 2>/dev/null || true
    cp "$tmp/SHA256SUMS.sig" /usr/local/share/tailscale-SHA256SUMS.sig 2>/dev/null || true

    ensure_cron
    rcctl restart tailscaled >/dev/null 2>&1 || true

    if health_check "$want"; then
        log "OK: running $want"
        return 0
    fi

    log "health check failed, rolling back"
    if [ -x "${BIN}.prev" ]; then
        cp -p "${BIN}.prev" "$BIN"
        rcctl restart tailscaled >/dev/null 2>&1 || true
        sleep 10
        log "post-rollback: $(running_version) state=$(backend_state)"
    fi
    die "update to $want failed and was rolled back"
}

do_revert() {
    [ -x "${BIN}.prev" ] || die "no ${BIN}.prev to restore"
    cp -p "${BIN}.prev" "$BIN"
    rcctl restart tailscaled >/dev/null 2>&1 || true
    sleep 8
    log "reverted: $(running_version) state=$(backend_state)"
}

do_status() {
    echo "running:       $(running_version) ($(backend_state))"
    echo "prev binary:   $([ -x "${BIN}.prev" ] && echo present || echo none)"
    echo "cron:          $(crontab -l 2>/dev/null | grep -q install-openbsd.sh && echo yes || echo NO)"
    echo "os release:    $(uname -r) (Go supports the two most recent)"
}

case "${1:-install}" in
    install)
        if [ "$0" != "$SELF" ]; then
            cp "$0" "$SELF" && chmod 755 "$SELF"
        fi
        do_update
        ;;
    update) do_update ;;
    revert) do_revert ;;
    status) do_status ;;
    *) echo "Usage: $0 {install|update|revert|status}"; exit 1 ;;
esac
