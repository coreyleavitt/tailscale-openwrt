#!/bin/sh
# GL.iNet KVM (GL-RM10, Buildroot) Tailscale updater
#
# Replaces the vendor's forked ROM tailscaled (read-only /rom, dev-build,
# updates only with firmware) with the trusted self-built binary from this
# repo's releases, and keeps it current via cron. The ROM binary is never
# touched: the init script gets a guarded override that prefers
# /userdata/tailscale/tailscaled when present and executable, so removing
# or breaking the override binary always falls back to the vendor build.
# tailscaled state stays in the vendor statedir (/etc/kvmd/user/tailscale),
# so the node identity, route approvals, and the GL UI enable-toggle are
# unaffected by the swap.
#
# Runs on busybox ash; needs curl (or wget), jq, sha256sum -- all present
# in rm10 firmware 1.9.x.
#
# Verification note (deviation from install-glinet.sh H1): the release's
# SHA256SUMS is usign-signed in CI, but Buildroot has no usign, so runtime
# verification here is HTTPS + sha256 against SHA256SUMS only. The .sig is
# downloaded and kept beside the binary for offline audit. If usign is
# ever added to the device, verify_signature() below is the seam.
#
# Usage:
#   install-glkvm.sh install   # first-time: patch init, install cron, update
#   install-glkvm.sh update    # fetch latest release if newer, swap, verify
#   install-glkvm.sh revert    # disable override, restart on ROM binary
#   install-glkvm.sh status    # show ROM/override/running versions

set -eu

REPO="coreyleavitt/tailscale-builds"
ARCH="aarch64_cortex-a53"
BASE="/userdata/tailscale"
INIT="/etc/init.d/S99tailscale"
MARKER="tailscale-builds override"
CRONTAB="/etc/crontabs/root"
CRON_LINE="30 4 * * 0 $BASE/install-glkvm.sh update >/tmp/tailscale-update.log 2>&1"
API="https://api.github.com/repos/$REPO/releases"

log() { echo "[glkvm-ts] $*"; logger -t glkvm-ts "$*" 2>/dev/null || true; }
die() { log "ERROR: $*"; exit 1; }

fetch() {
    # fetch <url> <outfile>
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 15 -o "$2" "$1"
    else
        wget -q -T 15 -O "$2" "$1"
    fi
}

latest_version() {
    fetch "$API/latest" /tmp/ts-latest.json
    jq -r '.tag_name' /tmp/ts-latest.json | sed 's/^v//'
}

installed_version() {
    [ -f "$BASE/VERSION" ] && cat "$BASE/VERSION" || echo "none"
}

running_state() {
    "$BASE/tailscale" status --json 2>/dev/null | jq -r '.BackendState' || echo "unknown"
}

ensure_patched() {
    # init override, idempotent; survives until a firmware update replaces
    # the init script, after which the next update run re-applies it
    if ! grep -q "$MARKER" "$INIT"; then
        sed -i "/^DAEMON=/a [ -x $BASE/tailscaled ] && DAEMON=\"$BASE/tailscaled\" # $MARKER" "$INIT"
        log "patched $INIT with override"
    fi
    touch "$CRONTAB"
    if ! grep -q "install-glkvm.sh" "$CRONTAB"; then
        echo "$CRON_LINE" >> "$CRONTAB"
        log "installed weekly update cron"
    fi
}

health_check() {
    # wait for BackendState Running with the expected version
    want="$1"
    i=0
    while [ $i -lt 18 ]; do
        state="$(running_state)"
        if [ "$state" = "Running" ]; then
            got="$("$BASE/tailscale" version 2>/dev/null | head -1)"
            [ "$got" = "$want" ] && return 0
            # Running but wrong version = daemon is ROM binary; still healthy
            log "running but version is '$got' (wanted $want)"
            return 1
        fi
        sleep 5
        i=$((i + 1))
    done
    return 1
}

do_update() {
    mkdir -p "$BASE"
    want="$(latest_version)"
    [ -n "$want" ] && [ "$want" != "null" ] || die "could not determine latest release"
    have="$(installed_version)"
    if [ "$want" = "$have" ]; then
        log "already at $want"
        ensure_patched
        return 0
    fi
    log "updating $have -> $want"

    tmp="/tmp/ts-update.$$"
    mkdir -p "$tmp"
    trap 'rm -rf "$tmp"' EXIT

    base_url="https://github.com/$REPO/releases/download/v$want"
    fetch "$base_url/tailscaled_${want}_${ARCH}" "$tmp/tailscaled" || die "binary download failed"
    fetch "$base_url/SHA256SUMS" "$tmp/SHA256SUMS" || die "SHA256SUMS download failed"
    fetch "$base_url/SHA256SUMS.sig" "$tmp/SHA256SUMS.sig" || true

    want_sum="$(grep "tailscaled_${want}_${ARCH}\$" "$tmp/SHA256SUMS" | awk '{print $1}')"
    [ -n "$want_sum" ] || die "no checksum entry for tailscaled_${want}_${ARCH}"
    got_sum="$(sha256sum "$tmp/tailscaled" | awk '{print $1}')"
    [ "$got_sum" = "$want_sum" ] || die "checksum mismatch: got $got_sum want $want_sum"

    chmod 755 "$tmp/tailscaled"
    ln -sf tailscaled "$tmp/tailscale"
    ver_out="$("$tmp/tailscale" version 2>/dev/null | head -1)" || die "downloaded binary does not execute"
    [ "$ver_out" = "$want" ] || die "downloaded binary reports '$ver_out', expected $want"

    # stage: keep one previous generation for rollback
    [ -x "$BASE/tailscaled" ] && cp "$BASE/tailscaled" "$BASE/tailscaled.prev"
    mv "$tmp/tailscaled" "$BASE/tailscaled"
    ln -sf tailscaled "$BASE/tailscale"
    cp "$tmp/SHA256SUMS" "$BASE/SHA256SUMS" 2>/dev/null || true
    cp "$tmp/SHA256SUMS.sig" "$BASE/SHA256SUMS.sig" 2>/dev/null || true

    ensure_patched
    "$INIT" restart >/dev/null 2>&1 || true

    if health_check "$want"; then
        echo "$want" > "$BASE/VERSION"
        log "OK: running $want"
        return 0
    fi

    # rollback
    log "health check failed, rolling back"
    if [ -x "$BASE/tailscaled.prev" ]; then
        mv "$BASE/tailscaled.prev" "$BASE/tailscaled"
    else
        mv "$BASE/tailscaled" "$BASE/tailscaled.bad"
    fi
    "$INIT" restart >/dev/null 2>&1 || true
    sleep 10
    log "post-rollback state: $(running_state)"
    die "update to $want failed and was rolled back"
}

do_revert() {
    [ -x "$BASE/tailscaled" ] && mv "$BASE/tailscaled" "$BASE/tailscaled.disabled"
    rm -f "$BASE/VERSION"
    "$INIT" restart >/dev/null 2>&1 || true
    log "reverted to ROM binary; state: $(sleep 8; running_state)"
}

do_status() {
    echo "ROM binary:      $(/usr/bin/tailscale version 2>/dev/null | head -1)"
    echo "override binary: $([ -x "$BASE/tailscaled" ] && "$BASE/tailscale" version | head -1 || echo none)"
    echo "installed tag:   $(installed_version)"
    echo "backend state:   $(running_state)"
    echo "init patched:    $(grep -q "$MARKER" "$INIT" && echo yes || echo NO)"
    echo "cron installed:  $(grep -q install-glkvm.sh "$CRONTAB" 2>/dev/null && echo yes || echo NO)"
}

case "${1:-install}" in
    install)
        mkdir -p "$BASE"
        if [ "$0" != "$BASE/install-glkvm.sh" ]; then
            cp "$0" "$BASE/install-glkvm.sh" && chmod 755 "$BASE/install-glkvm.sh"
        fi
        do_update
        ;;
    update) do_update ;;
    revert) do_revert ;;
    status) do_status ;;
    *) echo "Usage: $0 {install|update|revert|status}"; exit 1 ;;
esac
