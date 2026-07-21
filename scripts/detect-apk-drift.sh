#!/bin/sh
# scripts/detect-apk-drift.sh
#
# Cron self-heal detection (RFC docs/rfc-apk-builds.md §4.6, slice C5). With
# apk/ipk failure isolation in place, an apk-path soft-failure (a signing
# outage, a Pages deploy hiccup) no longer fails the ipk release -- the
# GitHub Release still gets created. That is the correct isolation behavior,
# but it means `check-releases.yaml`'s existing `gh release view "$TAG"` gate
# now reads "done" even when the apk feed was never updated for that release
# -- the outage class the RFC exists to prevent, relocated from "imprimatur
# lies about /health" to "the release gate doesn't know apk is a thing". This
# script is the daily cron's other half: given the latest release tag and one
# arch's published `packages.adb`, decide whether the feed is caught up.
#
# Deliberately narrow and testable in isolation (no GitHub API calls here --
# the caller already has the release tag from check-releases.yaml's own
# "Get latest Tailscale release" step; this script only compares that tag
# against a feed index, local file or URL). Reuses feed-guard.sh's
# read-version (itself reusing the same fetch/adb-parsing primitives as
# check-monotonic/verify-tree, RFC task note "has verify-tree/monotonicity
# you'll reuse") and apk's own version comparator (`apk version -t`) --
# never a hand-rolled version compare, same discipline as feed-guard.sh.
#
# Exit codes (distinct, never conflated -- loud-failure discipline):
#   0  IN SYNC    -- feed version >= release version; no action needed.
#   1  DRIFT       -- feed missing entirely, OR feed version < release
#                     version; the caller should auto-fire a republish
#                     dispatch (RFC: "auto-fire the republish dispatch on
#                     mismatch").
#   2  HARD ERROR  -- a genuine fetch failure (network/5xx/DNS), NOT a
#                     confirmed-missing feed. Refuses to guess: a transient
#                     blip must never be treated as "safe to auto-republish"
#                     (an ill-timed publish landing mid-outage is its own
#                     risk) nor as "everything's fine" (that would be exactly
#                     the silent-failure trap this RFC exists to close).
#
# Usage:
#   detect-apk-drift.sh <release-tag> <feed-index-source> [--pkgname NAME] [--pkg-release N]
#
# <release-tag>        e.g. "v1.98.8" (the tag_name of the latest upstream
#                       Tailscale release, as check-releases.yaml already
#                       computes it).
# <feed-index-source>  http(s):// URL or local file path to one arch's
#                       packages.adb (a local path is what
#                       tests/apk/failure-isolation.sh uses to test this
#                       hermetically, mirroring feed-guard.sh's own
#                       local-file test affordance).
# --pkg-release N       defaults to 1 -- check-releases.yaml's own dispatch
#                       always builds with pkg_release=1
#                       (`gh workflow run build-tailscale.yaml ... -f
#                       pkg_release="1"`), so the release tag's implied apk
#                       version is always "<tag-without-v>-r<N>". Overridable
#                       for a manually-dispatched non-default release.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FEED_GUARD="${SCRIPT_DIR}/feed-guard.sh"

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || { echo "detect-apk-drift.sh: required command '$1' not found on PATH" >&2; exit 2; }
}
require_cmd apk

[ $# -ge 2 ] || { echo "usage: detect-apk-drift.sh <release-tag> <feed-index-source> [--pkgname NAME] [--pkg-release N]" >&2; exit 2; }
RELEASE_TAG="$1"; FEED_SRC="$2"; shift 2

PKGNAME="tailscale"
PKG_RELEASE="1"
while [ $# -gt 0 ]; do
    case "$1" in
        --pkgname) PKGNAME="$2"; shift 2 ;;
        --pkg-release) PKG_RELEASE="$2"; shift 2 ;;
        *) echo "detect-apk-drift.sh: unknown argument '$1'" >&2; exit 2 ;;
    esac
done

RELEASE_VERSION="${RELEASE_TAG#v}-r${PKG_RELEASE}"

ERR_LOG=$(mktemp)
trap 'rm -f "${ERR_LOG}"' EXIT

set +e
FEED_VERSION=$(sh "${FEED_GUARD}" read-version "${FEED_SRC}" --pkgname "${PKGNAME}" 2>"${ERR_LOG}")
RC=$?
set -e

if [ "${RC}" -eq 3 ]; then
    echo "DRIFT: no apk feed index found at ${FEED_SRC} for release ${RELEASE_TAG} -- release exists but apk was never published (self-heal should fire)"
    exit 1
elif [ "${RC}" -ne 0 ]; then
    echo "ERROR: could not read feed index version at ${FEED_SRC}: $(cat "${ERR_LOG}")" >&2
    exit 2
fi

if ! CMP=$(apk version -t "${RELEASE_VERSION}" "${FEED_VERSION}" 2>"${ERR_LOG}"); then
    echo "ERROR: 'apk version -t ${RELEASE_VERSION} ${FEED_VERSION}' exited unexpectedly ($(cat "${ERR_LOG}")) -- not one of the documented in-sync/drift outcomes, refusing to guess" >&2
    exit 2
fi
case "${CMP}" in
    '>')
        echo "DRIFT: release ${RELEASE_VERSION} > feed ${FEED_VERSION} at ${FEED_SRC} -- apk feed is stale, self-heal should fire"
        exit 1
        ;;
    *)
        echo "IN SYNC: feed ${FEED_VERSION} at ${FEED_SRC} matches or is ahead of release ${RELEASE_VERSION} (apk version -t: '${CMP}')"
        exit 0
        ;;
esac
