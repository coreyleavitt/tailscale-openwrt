#!/bin/sh
# scripts/probe-feed.sh
#
# Synthetic post-launch feed/cert probe (RFC docs/rfc-apk-builds.md §4.6,
# slice C5). Everything else in this repo's apk pipeline only checks the
# feed AT PUBLISH TIME (C3's verify-tree, run once right after a deploy).
# Nothing catches *silent decay* of the static feed BETWEEN releases -- a
# Pages custom-domain cert renewal failure, DNS/CNAME drift, a Pages outage
# -- none of which touch a CI job, so none of the existing publish-time
# checks would ever see them. This script is meant to be piggybacked on the
# same daily cron as the check-releases.yaml keepalive: a cheap, frequent,
# standalone "is the feed still trustworthy and current" check against the
# LIVE production URL, independent of any build.
#
# Three checks, in order, each loud and distinct (never conflated):
#   1. TLS/cert validity  -- a plain `curl -fsS https://...` (no -k) fails
#      closed on an expired/self-signed/wrong-host certificate exactly like
#      a real `apk update` on a device would (apk fetches over HTTPS with
#      normal cert validation). A curl failure whose stderr mentions
#      "certificate" is reported as a cert-class failure specifically (not
#      lumped in with "network unreachable"), since the remediation is
#      different (renew the cert / fix DNS vs. "Pages is down").
#   2. Signature validity -- reuses scripts/adb-sign.py's new `verify`
#      subcommand (RFC C5 addition) to confirm the served index's
#      ADB_BLOCK_SIG cryptographically verifies against the PINNED public
#      key (fetched from the same feed, over the same TLS check) -- the
#      exact EVP_DigestVerify(sha512)->DER path a real device's apk uses
#      (B0 spike). This is deliberately NOT tests/apk/feed-guard.sh
#      verify-tree's job (that is a content-HASH walk against a known-good
#      LOCAL tree, C3's publish-time propagation-skew check) -- this probe
#      has no local tree to compare against by design (it runs standalone,
#      long after the publish that produced the live feed) and instead
#      re-proves trust from first principles against the pinned key.
#   3. Version currency -- the served index's package version must match
#      the latest GitHub release tag (the "matches the latest release" bullet
#      of §4.6) -- reuses the exact same apk-version-comparator discipline as
#      scripts/detect-apk-drift.sh (this script and that one deliberately
#      overlap in what they detect -- a stale feed -- but from different
#      angles: detect-apk-drift.sh is the self-heal trigger keyed off the
#      release-check cron's own tag lookup; this probe is feed-health-first
#      and also catches a feed that regressed AFTER already being caught up,
#      e.g. an accidental downgrade republish that somehow bypassed the
#      monotonicity guard).
#
# On ANY failure, reuses the shared scripts/notify-alert.sh channel (RFC:
# "reuse the alert channel on failure") -- this script does not implement
# its own separate notification path.
#
# Usage:
#   probe-feed.sh <arch-feed-base-url> <pubkey-url> <release-tag> \
#       [--pkgname NAME] [--pkg-release N]
#
# <arch-feed-base-url>  e.g. https://apk.leavitt.dev/apk/aarch64_cortex-a53
#                        (one arch is enough to detect cert/DNS/signature
#                        decay -- they share the same domain/cert/key;
#                        per-arch INDEX CONTENT decay is check-monotonic's
#                        and verify-tree's job at publish time, not this
#                        probe's).
# <pubkey-url>           e.g. https://apk.leavitt.dev/apk/keys/tailscale.pem
#                        -- fetched fresh each run (not a locally committed
#                        copy) so a corrupted/replaced SERVED pubkey is
#                        itself part of what this probe can catch.
# <release-tag>          e.g. v1.98.8 (from check-releases.yaml's own
#                        "Get latest Tailscale release" step).
#
# Exit: 0 all three checks pass. 1 one or more checks failed (loud, with a
# reason per failure printed to stderr and passed to notify-alert.sh).
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ADB_SIGN_PY="${SCRIPT_DIR}/adb-sign.py"

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || { echo "probe-feed.sh: required command '$1' not found on PATH" >&2; exit 2; }
}
require_cmd curl
require_cmd openssl
require_cmd python3
require_cmd apk

[ $# -ge 3 ] || { echo "usage: probe-feed.sh <arch-feed-base-url> <pubkey-url> <release-tag> [--pkgname NAME] [--pkg-release N]" >&2; exit 2; }
BASE_URL="$1"; PUBKEY_URL="$2"; RELEASE_TAG="$3"; shift 3

PKGNAME="tailscale"
PKG_RELEASE="1"
while [ $# -gt 0 ]; do
    case "$1" in
        --pkgname) PKGNAME="$2"; shift 2 ;;
        --pkg-release) PKG_RELEASE="$2"; shift 2 ;;
        *) echo "probe-feed.sh: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

FAILED=0
REASONS=""
record_fail() {
    FAILED=1
    REASONS="${REASONS}${REASONS:+; }$1"
    echo "FAIL: $1" >&2
}

# --- 1. TLS/cert validity + fetch the served index ------------------------
ADB="${WORK}/packages.adb"
if curl -fsS -o "${ADB}" "${BASE_URL%/}/packages.adb" 2>"${WORK}/curl-idx.err"; then
    echo "OK: fetched ${BASE_URL%/}/packages.adb over a validly-certified HTTPS connection"
else
    ERRTXT=$(cat "${WORK}/curl-idx.err" 2>/dev/null || true)
    if printf '%s' "${ERRTXT}" | grep -qi 'certificate'; then
        record_fail "TLS/cert validity check FAILED for ${BASE_URL} (${ERRTXT})"
    else
        record_fail "could not fetch ${BASE_URL%/}/packages.adb (${ERRTXT})"
    fi
fi

# --- fetch the pinned pubkey (same domain/cert) ----------------------------
PUBKEY="${WORK}/tailscale.pem"
if curl -fsS -o "${PUBKEY}" "${PUBKEY_URL}" 2>"${WORK}/curl-key.err"; then
    echo "OK: fetched pubkey at ${PUBKEY_URL}"
else
    ERRTXT=$(cat "${WORK}/curl-key.err" 2>/dev/null || true)
    if printf '%s' "${ERRTXT}" | grep -qi 'certificate'; then
        record_fail "TLS/cert validity check FAILED fetching pubkey at ${PUBKEY_URL} (${ERRTXT})"
    else
        record_fail "could not fetch pubkey at ${PUBKEY_URL} (${ERRTXT})"
    fi
fi

# --- 2. signature validity --------------------------------------------------
if [ -s "${ADB}" ] && [ -s "${PUBKEY}" ]; then
    if VERIFY_OUT=$(python3 "${ADB_SIGN_PY}" verify "${ADB}" "${PUBKEY}" 2>&1); then
        echo "OK: served index signature verifies against the pinned pubkey (${VERIFY_OUT})"
    else
        record_fail "served index FAILED signature verification against the pinned pubkey (${VERIFY_OUT})"
    fi
else
    echo "SKIP: signature check skipped (index or pubkey not fetched, already recorded as a failure above)" >&2
fi

# --- 3. version currency ----------------------------------------------------
if [ -s "${ADB}" ]; then
    FEED_VERSION=$(apk adbdump "${ADB}" 2>/dev/null | awk -v pkg="${PKGNAME}" '
        /^  - name: / { name = $3 }
        name == pkg && /^    version: / { print $2; exit }
    ')
    if [ -z "${FEED_VERSION}" ]; then
        record_fail "served index has no '${PKGNAME}' package entry (unexpected feed shape)"
    else
        EXPECTED_VERSION="${RELEASE_TAG#v}-r${PKG_RELEASE}"
        CMP=$(apk version -t "${EXPECTED_VERSION}" "${FEED_VERSION}" 2>/dev/null || echo '?')
        if [ "${CMP}" = "=" ] || [ "${CMP}" = "<" ]; then
            echo "OK: served index version ${FEED_VERSION} matches or is ahead of latest release ${RELEASE_TAG} (expected ${EXPECTED_VERSION})"
        else
            record_fail "served index version '${FEED_VERSION}' does NOT match latest release ${RELEASE_TAG} (expected ${EXPECTED_VERSION}, apk version -t: '${CMP}')"
        fi
    fi
else
    echo "SKIP: version check skipped (index not fetched, already recorded as a failure above)" >&2
fi

if [ "${FAILED}" -ne 0 ]; then
    echo "PROBE FAILED: ${REASONS}" >&2
    exit 1
fi
echo "PROBE OK: ${BASE_URL} -- TLS/cert, signature, and version currency all verified"
