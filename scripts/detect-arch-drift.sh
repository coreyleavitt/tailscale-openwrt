#!/bin/sh
# scripts/detect-arch-drift.sh
#
# Weekly arch-drift check (RFC docs/rfc-apk-arch-coverage.md §5.7, slice S9 --
# the final slice). `arches.json` is this repo's single source of truth for
# "which OpenWrt package arches exist" (35 rows: 30 feasible + 5 infeasible-
# but-tracked, e.g. powerpc*, arm_fa526, armeb_xscale -- real OpenWrt arches
# Go can't target). Nothing keeps that table honest against upstream: if
# OpenWrt adds a new target arch, or drops one entirely, arches.json just
# silently rots -- the same class of "nobody's watching" gap
# detect-apk-drift.sh (RFC docs/rfc-apk-builds.md §4.6) closed for package
# VERSION currency. This closes it for the ARCH SET itself, mirroring that
# script's design discipline exactly:
#   - narrow, testable in isolation (tests/apk/arch-drift.sh, no live cron
#     needed)
#   - the live-index source is an INJECTABLE arg, URL or local file, same
#     ok/notfound/error fetch shape as feed-guard.sh's fetch_or_status (not a
#     shared subcommand -- feed-guard.sh's fetch helper is adb/JSON-index
#     specific and private to that script; this parses an OpenWrt directory
#     LISTING, a different shape entirely, so this mirrors the same curl
#     invocation rather than bolting an unrelated parse mode onto
#     feed-guard.sh)
#   - distinct, never-conflated exit codes
#
# UNLIKE detect-apk-drift.sh, this is warn-only, never a self-heal trigger
# (RFC §5.7: "warning (not failing) on additions/removals"). Retiring a
# tracked arch is a deliberate, reviewed human decision (the "Arch
# Decommission Runbook" this script's removals output cross-references,
# docs/MAINTAINING.md#arch-decommission-runbook) -- auto-firing a republish
# or an arches.json edit from a drift signal here would be exactly the kind
# of unreviewed depublish that runbook exists to prevent. The calling
# workflow (.github/workflows/check-arch-drift.yaml) enforces the warn-only
# contract; this script only ever reports, it never mutates anything.
#
# Exit codes (distinct, never conflated -- loud-failure discipline, same
# shape as detect-apk-drift.sh):
#   0  NO DRIFT    -- the live OpenWrt package-arch set and arches.json's
#                     full name set (feasible + infeasible) match exactly.
#   1  DRIFT        -- ADVISORY. One or both of:
#                        additions: arch dirs in the live index NOT in
#                          arches.json (a new upstream arch we don't track).
#                        removals: arches.json names NOT in the live index
#                          (OpenWrt dropped a tracked arch -- a decommission
#                          candidate; see docs/MAINTAINING.md
#                          #arch-decommission-runbook).
#                     Never auto-fixed. The caller warns; it must NOT fail
#                     the job on this exit code (§5.7: warn-only).
#   2  HARD ERROR   -- the index could not be fetched (network/5xx/DNS) OR
#                     fetched but unparseable/empty (garbage content, zero
#                     arch-shaped directory entries). Refuses to guess: a
#                     transient blip or a malformed source must never be
#                     read as "confirmed no drift" (that would silently mask
#                     a real removal) nor as "confirmed drift" (that would
#                     cry wolf on a fetch hiccup, not an actual upstream
#                     change).
#
# Usage:
#   detect-arch-drift.sh <index-source> [arches-json]
#
# <index-source>  http(s):// URL or local file path to the live OpenWrt
#                 package-arch index -- an HTML directory listing (OpenWrt's
#                 dir-index.cgi output) whose top-level entries are one
#                 subdirectory per package arch, e.g.
#                 https://downloads.openwrt.org/releases/25.12.0/packages/
#                 (the pinned release's packages/ dir -- confirmed live
#                 2026-07-22: its 35 top-level directory entries match
#                 arches.json's 35 names exactly). A local file is what
#                 tests/apk/arch-drift.sh uses to test this hermetically, no
#                 network required, mirroring detect-apk-drift.sh's own
#                 local-file test affordance.
# [arches-json]   defaults to arches.json at the repo root (this script's
#                 parent directory). Diffs against ALL rows' `.name`s --
#                 feasible AND infeasible -- since infeasible rows are
#                 deliberately-tracked known arches that legitimately appear
#                 in the live index too; they must never register as drift.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || { echo "detect-arch-drift.sh: required command '$1' not found on PATH" >&2; exit 2; }
}
require_cmd curl
require_cmd jq

[ $# -ge 1 ] || { echo "usage: detect-arch-drift.sh <index-source> [arches-json]" >&2; exit 2; }
INDEX_SRC="$1"
ARCHES_JSON="${2:-${REPO_ROOT}/arches.json}"

[ -f "${ARCHES_JSON}" ] || { echo "detect-arch-drift.sh: arches.json not found at ${ARCHES_JSON}" >&2; exit 2; }

WORK=$(mktemp -d)
ERR_LOG="${WORK}/err.log"
trap 'rm -rf "${WORK}"' EXIT

# --- fetch the index (URL or local file), mirroring feed-guard.sh's
# fetch_or_status ok/notfound/error curl shape -----------------------------
INDEX_FILE="${WORK}/index.html"
case "${INDEX_SRC}" in
    http://*|https://*)
        if CODE=$(curl -fsS -o "${INDEX_FILE}" -w '%{http_code}' "${INDEX_SRC}" 2>"${ERR_LOG}"); then
            :
        else
            RC=$?
            echo "ERROR: could not fetch live arch index at ${INDEX_SRC} (curl exit=${RC} http_code=${CODE:-000}: $(cat "${ERR_LOG}" 2>/dev/null)) -- refusing to guess" >&2
            exit 2
        fi
        ;;
    *)
        if [ ! -e "${INDEX_SRC}" ]; then
            echo "ERROR: live arch index source '${INDEX_SRC}' not found -- refusing to guess" >&2
            exit 2
        fi
        if ! cp "${INDEX_SRC}" "${INDEX_FILE}" 2>"${ERR_LOG}"; then
            echo "ERROR: could not read live arch index at ${INDEX_SRC}: $(cat "${ERR_LOG}" 2>/dev/null)" >&2
            exit 2
        fi
        ;;
esac

# --- parse: OpenWrt's dir-index.cgi lists each subdirectory as
# `<a href="NAME/">NAME</a>/` (href and visible text identical, followed
# immediately by a literal "/" -- breadcrumb links at the top of the page
# have a space before their separating "/" and don't match). Confirmed live
# against https://downloads.openwrt.org/releases/25.12.0/packages/ : this
# extracts exactly the 35 arch subdirectories, nothing else. Filtered to a
# sane arch-name shape as a defensive guard against a malformed/unexpected
# page format producing spurious matches. -----------------------------------
LIVE_NAMES=$(grep -oE '<a href="[^"]+/">[^<]+</a>/' "${INDEX_FILE}" 2>/dev/null \
    | sed -E 's#<a href="([^"]+)/">.*#\1#' \
    | grep -E '^[a-z0-9][a-z0-9_.-]*$' \
    | sort -u || true)

if [ -z "${LIVE_NAMES}" ]; then
    echo "ERROR: no arch-shaped directory entries parsed out of ${INDEX_SRC} -- empty, garbage, or unexpected index format, refusing to guess" >&2
    exit 2
fi

TRACKED_NAMES=$(jq -r '.[].name' "${ARCHES_JSON}" | sort -u)

LIVE_FILE="${WORK}/live.txt"
TRACKED_FILE="${WORK}/tracked.txt"
printf '%s\n' "${LIVE_NAMES}" > "${LIVE_FILE}"
printf '%s\n' "${TRACKED_NAMES}" > "${TRACKED_FILE}"

# comm needs sorted files, not process substitution (POSIX sh, no bashisms --
# same discipline as the rest of this repo's scripts/*.sh).
ADDITIONS=$(comm -23 "${LIVE_FILE}" "${TRACKED_FILE}")
REMOVALS=$(comm -13 "${LIVE_FILE}" "${TRACKED_FILE}")

if [ -z "${ADDITIONS}" ] && [ -z "${REMOVALS}" ]; then
    echo "NO DRIFT: live OpenWrt arch index at ${INDEX_SRC} matches arches.json exactly ($(printf '%s\n' "${TRACKED_NAMES}" | wc -l | tr -d ' ') arches)"
    exit 0
fi

echo "DRIFT: live OpenWrt arch index at ${INDEX_SRC} differs from arches.json"
if [ -n "${ADDITIONS}" ]; then
    echo ""
    echo "ADDITIONS (new arches upstream, not yet tracked in arches.json):"
    printf '%s\n' "${ADDITIONS}" | sed 's/^/  + /'
fi
if [ -n "${REMOVALS}" ]; then
    echo ""
    echo "REMOVALS (arches.json names no longer in the live OpenWrt index -- decommission candidates):"
    printf '%s\n' "${REMOVALS}" | sed 's/^/  - /'
    echo ""
    echo "REMOVALS are a signal to consider retiring these arches from arches.json deliberately -- see the Arch Decommission Runbook (docs/MAINTAINING.md#arch-decommission-runbook) for the reviewed, --allow-depublish step. This check is advisory only; it never edits arches.json or republishes anything itself."
fi
exit 1
