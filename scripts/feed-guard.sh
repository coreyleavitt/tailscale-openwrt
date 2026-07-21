#!/bin/sh
# scripts/feed-guard.sh
#
# CI-side "does this publish do the right thing to the tree" logic for the
# apk feed (RFC docs/rfc-apk-builds.md §4.3, slice C3). Three related, but
# distinct, per-arch operations over a `packages.adb` + `*.apk` tree, kept in
# one script because they share the same primitives (fetch a URL-or-local-
# path source with a loud/silent-failure distinction; read fields out of
# `apk adbdump`'s textual index dump via the pinned host `apk` binary) and
# all exist to protect the SAME invariant: a client that runs `apk update`
# against this feed, at any point during or after a publish, must never end
# up worse off than before (a downgrade, or a hard 404 on a blob its cached
# index still names).
#
#   check-monotonic  -- refuse to publish a version that is not strictly
#                        greater than the currently-live one (prevents a
#                        signed downgrade via republish/backfill order-
#                        inversion, §4.3/§8), unless --force. A confirmed-
#                        absent live index (bootstrap / genuine first
#                        publish) ALSO requires --force: the feed host is
#                        untrusted-by-design and a 404 from Pages/CDN is not
#                        a guaranteed "truly absent", so it gets no more of
#                        a free pass than any other rejection here.
#   plan-retention   -- compute the last-N package-blob filenames to keep in
#                        the published tree (index stays latest-only per §2/
#                        O5; only the BLOBS get retained, so a client holding
#                        a briefly-stale cached index can still resolve the
#                        version it references instead of a hard 404 -- GH
#                        Pages replaces the whole tree on every deploy).
#   verify-tree      -- post-publish integrity check: fetch the served
#                        `packages.adb` and every package it references, and
#                        assert each resolves with the SAME content-hash apk
#                        itself would compute (guards CDN propagation skew --
#                        apk fails closed on a hash mismatch on a real
#                        device, so this is a reliability check, not a trust
#                        check; trust/signature verification is C2's job).
#   read-version     -- print a package's version out of a local/URL index,
#                        distinguishing ok/notfound/error exactly like
#                        check-monotonic does (RFC §4.6 slice C5: reused by
#                        scripts/detect-apk-drift.sh so the daily cron's
#                        self-heal check doesn't need its own duplicate
#                        fetch+adbdump plumbing -- one place understands "how
#                        to read a package version out of a maybe-remote
#                        index", shared by the publish-time monotonicity
#                        guard and the post-publish drift detector).
#
# Version comparison uses apk's OWN comparator (`apk version -t A B`), not a
# hand-rolled semver/dpkg-style compare -- apk's version grammar has its own
# rules (the `-rN` release-suffix ordering, letter suffixes, `_pre`/`_rc`,
# etc.) that a reimplementation would inevitably get subtly wrong for some
# input, exactly the class of bug this repo's other apk-facing scripts
# (adb-sign.py) go out of their way to avoid by shelling out to real tools
# rather than reimplementing them. Likewise `verify-tree`'s hash check
# doesn't reimplement apk v3's package content-hash algorithm -- it re-index
# the fetched bytes with the real `apk mkndx` and compares the resulting
# `hashes:` field against the originally published index's, using apk
# itself as the oracle for "what hash would a real device compute".
#
# Requires: apk (host apk-tools 3.0.2, extracted by the `apk-tools` Docker
# stage in tailscale-package/Dockerfile -- see tests/apk/host-apk.sh and
# lib.sh's extract_apk_tools_binary), curl, jq.
#
# Loud-failure discipline (RFC guiding constraint #2, §1): every source
# lookup (the live index, the live retention manifest) distinguishes THREE
# outcomes, never conflating the last two:
#   ok       -- fetched/read successfully
#   notfound -- confirmed absent (HTTP 404, or local file does not exist)
#               -- this is the legitimate "first publish ever" bootstrap
#               case. Callers decide whether/how to proceed on it:
#               check-monotonic treats it the same as "not strictly
#               greater than live" -- it requires --force before proceeding,
#               since the feed host is untrusted-by-design and a 404 isn't
#               guaranteed to mean "truly absent" rather than "CDN hiccup
#               shaped like a 404" (M10).
#   error    -- anything else (network timeout, 5xx, DNS failure, permission
#               error) -- NEVER silently treated as "notfound"/"proceed".
#               A transient fetch failure must not look like a green light.
#
# Usage:
#   feed-guard.sh check-monotonic <new.adb> <live-source> [--pkgname NAME] [--force]
#   feed-guard.sh plan-retention <live-retained-source> <new-filename> [--n N]
#   feed-guard.sh verify-tree <tree-dir> <base-url>
#   feed-guard.sh read-version <source> [--pkgname NAME]
#
# <live-source> / <live-retained-source> may be an http(s):// URL (the real
# Pages URL in CI) or a local file path (what tests/apk/feed-publish.sh uses
# to test this hermetically against a plain `python3 -m http.server`, per
# RFC §6 slice C3's "testable locally, no live Pages deploy required").

set -eu

DEFAULT_PKGNAME="tailscale"
DEFAULT_RETAIN_N=3

TMPERR=$(mktemp)
trap 'rm -f "${TMPERR}"' EXIT

die() {
    echo "feed-guard.sh: $1" >&2
    exit 2
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command '$1' not found on PATH"
}

require_cmd curl
require_cmd jq
# `apk` is only required by check-monotonic/verify-tree (adbdump/mkndx),
# not plan-retention (pure jq over a JSON manifest) -- checked per-subcommand
# below so plan-retention stays usable without the (heavier) pinned apk
# binary on PATH.

# --- shared: fetch a URL-or-local-path source, distinguishing ok/notfound/error ---
# Sets FETCH_STATUS (ok|notfound|error) and, on error, FETCH_ERROR.
FETCH_STATUS=""
FETCH_ERROR=""
fetch_or_status() {
    _src="$1"; _dest="$2"
    case "${_src}" in
        http://*|https://*)
            if _code=$(curl -fsS -o "${_dest}" -w '%{http_code}' "${_src}" 2>"${TMPERR}"); then
                FETCH_STATUS=ok
            else
                _rc=$?
                if [ "${_code:-000}" = "404" ]; then
                    FETCH_STATUS=notfound
                else
                    FETCH_STATUS=error
                    FETCH_ERROR="curl exit=${_rc} http_code=${_code:-000}: $(cat "${TMPERR}" 2>/dev/null)"
                fi
            fi
            ;;
        *)
            if [ ! -e "${_src}" ]; then
                FETCH_STATUS=notfound
            elif cp "${_src}" "${_dest}" 2>"${TMPERR}"; then
                FETCH_STATUS=ok
            else
                FETCH_STATUS=error
                FETCH_ERROR="$(cat "${TMPERR}" 2>/dev/null)"
            fi
            ;;
    esac
}

# --- shared: read fields out of `apk adbdump`'s textual index dump ---------
# adbdump emits (per package, in order):
#   "  - name: <name>"
#   "    version: <version>"
#   "    hashes: <hex>"
#   "    arch: <arch>"
#   ...
# adb_field adb_file pkgname field -> prints the field's value for that
# package (empty output, no error, if the package/field isn't present --
# callers check for empty and decide bootstrap-vs-hard-error themselves).
adb_field() {
    _adb="$1"; _pkg="$2"; _field="$3"
    apk adbdump "${_adb}" 2>/dev/null | awk -v pkg="${_pkg}" -v field="${_field}:" '
        /^  - name: / { name = $3 }
        name == pkg && $1 == field { print $2; exit }
    '
}

# adb_list adb_file -> "<name> <version>" one line per package in the index
# (used by verify-tree, which walks EVERY referenced package, not just one).
adb_list() {
    _adb="$1"
    apk adbdump "${_adb}" 2>/dev/null | awk '
        /^  - name: / { name = $3 }
        /^    version: / { print name" "$2 }
    '
}

# =========================================================================
# check-monotonic
# =========================================================================
cmd_check_monotonic() {
    require_cmd apk
    [ $# -ge 2 ] || die "usage: check-monotonic <new.adb> <live-source> [--pkgname NAME] [--force]"
    NEW_ADB="$1"; LIVE_SRC="$2"; shift 2
    PKGNAME="${DEFAULT_PKGNAME}"
    FORCE=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --pkgname) PKGNAME="$2"; shift 2 ;;
            --force) FORCE=1; shift ;;
            *) die "check-monotonic: unknown argument '$1'" ;;
        esac
    done

    [ -f "${NEW_ADB}" ] || die "check-monotonic: new index '${NEW_ADB}' not found"
    NEW_VERSION=$(adb_field "${NEW_ADB}" "${PKGNAME}" "version")
    [ -n "${NEW_VERSION}" ] || die "check-monotonic: package '${PKGNAME}' not found in new index ${NEW_ADB} (build bug, not a guard decision)"

    WORK=$(mktemp -d)
    LIVE_ADB="${WORK}/live.adb"

    fetch_or_status "${LIVE_SRC}" "${LIVE_ADB}"
    case "${FETCH_STATUS}" in
        notfound)
            rm -rf "${WORK}"
            if [ "${FORCE}" -eq 1 ]; then
                echo "OK: no live index at ${LIVE_SRC} -- --force given, allowing ${PKGNAME} ${NEW_VERSION} as a first publish"
                exit 0
            fi
            die "check-monotonic: no live index found at ${LIVE_SRC} (HTTP 404 or missing local file) -- refusing to auto-allow a 'first publish' on an untrusted feed host without confirmation (a 404 from Pages/a CDN is not a guaranteed 'truly absent'; every other rejection here also requires --force, and this is no exception). If this really is the first-ever publish, rerun with --force to confirm it deliberately."
            ;;
        error)
            rm -rf "${WORK}"
            die "check-monotonic: could not fetch live index at ${LIVE_SRC} (${FETCH_ERROR}) -- refusing to guess, publish BLOCKED (this is a transient/network failure, not 'no live index yet' -- rerun once resolved, or pass --force only if you have independently confirmed it is safe)"
            ;;
    esac

    LIVE_VERSION=$(adb_field "${LIVE_ADB}" "${PKGNAME}" "version")
    rm -rf "${WORK}"
    [ -n "${LIVE_VERSION}" ] || die "check-monotonic: live index at ${LIVE_SRC} fetched OK but has no '${PKGNAME}' package -- unexpected live-feed shape, refusing to guess"

    if ! CMP=$(apk version -t "${NEW_VERSION}" "${LIVE_VERSION}" 2>"${TMPERR}"); then
        die "check-monotonic: 'apk version -t ${NEW_VERSION} ${LIVE_VERSION}' exited unexpectedly ($(cat "${TMPERR}" 2>/dev/null)) -- not one of the documented ok/reject outcomes, refusing to guess"
    fi
    case "${CMP}" in
        '>')
            echo "OK: ${PKGNAME} ${NEW_VERSION} > live ${LIVE_VERSION} -- publish allowed"
            exit 0
            ;;
        *)
            if [ "${FORCE}" -eq 1 ]; then
                echo "WARNING: forcing publish of ${PKGNAME} ${NEW_VERSION} (${CMP}= live ${LIVE_VERSION}) -- --force override in effect"
                exit 0
            fi
            echo "FAIL: refusing to publish ${PKGNAME} ${NEW_VERSION}: not strictly greater than live ${LIVE_VERSION} (apk version -t says '${CMP}'). Pass --force to override deliberately (e.g. a genuine backfill)." >&2
            exit 1
            ;;
    esac
}

# =========================================================================
# plan-retention
# =========================================================================
cmd_plan_retention() {
    [ $# -ge 2 ] || die "usage: plan-retention <live-retained-source> <new-filename> [--n N]"
    LIVE_SRC="$1"; NEW_FILE="$2"; shift 2
    N="${DEFAULT_RETAIN_N}"
    while [ $# -gt 0 ]; do
        case "$1" in
            --n) N="$2"; shift 2 ;;
            *) die "plan-retention: unknown argument '$1'" ;;
        esac
    done

    WORK=$(mktemp -d)
    # L11: a validation failure below (die(), exit 2) must not skip cleanup
    # -- set the trap right after creating WORK, covering EVERY exit path
    # (including die()'s exit 2 mid-function) rather than relying on manual
    # `rm -rf` calls placed before each explicit exit, which is exactly the
    # kind of place one gets missed. Chained with the script-wide TMPERR
    # cleanup so this trap doesn't clobber that one.
    trap 'rm -rf "${WORK}"; rm -f "${TMPERR}"' EXIT
    LIVE_JSON="${WORK}/retained.json"

    fetch_or_status "${LIVE_SRC}" "${LIVE_JSON}"
    case "${FETCH_STATUS}" in
        ok)
            jq -e 'type == "array"' "${LIVE_JSON}" >/dev/null 2>&1 \
                || die "plan-retention: ${LIVE_SRC} did not contain a JSON array"
            PREV_JSON=$(cat "${LIVE_JSON}")
            ;;
        notfound)
            echo "OK: no live retention manifest at ${LIVE_SRC} -- first publish, starting fresh" >&2
            PREV_JSON="[]"
            ;;
        error)
            die "plan-retention: could not fetch live retention manifest at ${LIVE_SRC} (${FETCH_ERROR}) -- refusing to guess (a silent empty-list fallback here would risk losing track of blobs a stale-cached index still needs)"
            ;;
    esac

    # New filename first, then prior entries (deduped against the new one),
    # capped to N -- oldest beyond N is what naturally gets dropped from the
    # published tree (RFC §4.3: "only advance which one the index points
    # at" -- retention drops the *oldest* blob, not an arbitrary one).
    printf '%s\n' "${PREV_JSON}" | jq -c --arg new "${NEW_FILE}" --argjson n "${N}" '
        ([$new] + (map(select(. != $new)))) | .[0:$n]
    '
}

# =========================================================================
# verify-tree
# =========================================================================
cmd_verify_tree() {
    require_cmd apk
    [ $# -ge 2 ] || die "usage: verify-tree <tree-dir> <base-url>"
    TREE_DIR="$1"; BASE_URL="$2"

    [ -f "${TREE_DIR}/packages.adb" ] || die "verify-tree: ${TREE_DIR}/packages.adb not found locally"

    WORK=$(mktemp -d)
    FAIL=0

    SERVED_ADB="${WORK}/packages.adb"
    fetch_or_status "${BASE_URL%/}/packages.adb" "${SERVED_ADB}"
    if [ "${FETCH_STATUS}" != "ok" ]; then
        echo "FAIL: could not fetch ${BASE_URL%/}/packages.adb (${FETCH_STATUS}: ${FETCH_ERROR:-not found})" >&2
        rm -rf "${WORK}"
        exit 1
    fi
    if cmp -s "${TREE_DIR}/packages.adb" "${SERVED_ADB}"; then
        echo "OK: served packages.adb byte-identical to the published tree ($(sha256sum "${SERVED_ADB}" | awk '{print $1}'))"
    else
        echo "FAIL: served packages.adb DIFFERS from the published tree ${TREE_DIR}/packages.adb (local=$(sha256sum "${TREE_DIR}/packages.adb" | awk '{print $1}') served=$(sha256sum "${SERVED_ADB}" | awk '{print $1}'))" >&2
        FAIL=1
    fi

    adb_list "${TREE_DIR}/packages.adb" > "${WORK}/pkgs.list"
    if [ ! -s "${WORK}/pkgs.list" ]; then
        echo "FAIL: ${TREE_DIR}/packages.adb references no packages at all (empty index?)" >&2
        rm -rf "${WORK}"
        exit 1
    fi

    while read -r NAME VERSION; do
        [ -n "${NAME}" ] || continue
        EXPECTED_FILE="${NAME}-${VERSION}.apk"
        if [ ! -f "${TREE_DIR}/${EXPECTED_FILE}" ]; then
            echo "FAIL: index references ${NAME} ${VERSION} but ${TREE_DIR}/${EXPECTED_FILE} is not in the tree" >&2
            FAIL=1
            continue
        fi

        FETCHED="${WORK}/${EXPECTED_FILE}"
        fetch_or_status "${BASE_URL%/}/${EXPECTED_FILE}" "${FETCHED}"
        if [ "${FETCH_STATUS}" != "ok" ]; then
            echo "FAIL: ${NAME} ${VERSION}: could not fetch ${BASE_URL%/}/${EXPECTED_FILE} (${FETCH_STATUS}: ${FETCH_ERROR:-not found}) -- apk fails closed on this on a real device" >&2
            FAIL=1
            continue
        fi

        # Ground truth for "what hash would a real device compute for these
        # exact served bytes": re-index the fetched file with the real apk
        # tool, and compare against the hash the ORIGINAL published index
        # recorded for this name+version -- not a reimplementation of apk's
        # hash algorithm.
        REIDX="${WORK}/${NAME}-reindex.adb"
        if ! apk mkndx --allow-untrusted --compression none --output "${REIDX}" "${FETCHED}" >/dev/null 2>"${TMPERR}"; then
            echo "FAIL: ${NAME} ${VERSION}: apk mkndx could not index the served file (corrupt download?): $(cat "${TMPERR}")" >&2
            FAIL=1
            continue
        fi
        SERVED_HASH=$(adb_field "${REIDX}" "${NAME}" "hashes")
        EXPECTED_HASH=$(adb_field "${TREE_DIR}/packages.adb" "${NAME}" "hashes")
        if [ -z "${SERVED_HASH}" ] || [ -z "${EXPECTED_HASH}" ]; then
            echo "FAIL: ${NAME} ${VERSION}: could not determine hash (served='${SERVED_HASH}' expected='${EXPECTED_HASH}')" >&2
            FAIL=1
        elif [ "${SERVED_HASH}" = "${EXPECTED_HASH}" ]; then
            echo "OK: ${NAME} ${VERSION} (${EXPECTED_FILE}) resolves with matching hash (${SERVED_HASH})"
        else
            echo "FAIL: ${NAME} ${VERSION} (${EXPECTED_FILE}) HASH MISMATCH: index says ${EXPECTED_HASH}, served content hashes to ${SERVED_HASH} (propagation skew or corruption)" >&2
            FAIL=1
        fi
    done < "${WORK}/pkgs.list"

    rm -rf "${WORK}"
    [ "${FAIL}" -eq 0 ] || exit 1
    echo "OK: verify-tree passed for all entries in ${TREE_DIR}/packages.adb"
}

# =========================================================================
# read-version
# =========================================================================
# Prints a package's version to stdout and exits 0 on success. Exits 3 (not
# 2 -- deliberately distinct from die()'s hard-error 2) when the source is
# confirmed absent (HTTP 404 / local file missing) -- the legitimate
# "never published" case a caller (detect-apk-drift.sh) must be able to tell
# apart from a transient fetch error without scraping stdout text. A genuine
# fetch error still goes through die() (exit 2), same as check-monotonic --
# never silently reported as "not found".
cmd_read_version() {
    require_cmd apk
    [ $# -ge 1 ] || die "usage: read-version <source> [--pkgname NAME]"
    SRC="$1"; shift
    PKGNAME="${DEFAULT_PKGNAME}"
    while [ $# -gt 0 ]; do
        case "$1" in
            --pkgname) PKGNAME="$2"; shift 2 ;;
            *) die "read-version: unknown argument '$1'" ;;
        esac
    done

    WORK=$(mktemp -d)
    ADB="${WORK}/index.adb"

    fetch_or_status "${SRC}" "${ADB}"
    case "${FETCH_STATUS}" in
        notfound)
            rm -rf "${WORK}"
            echo "read-version: no index found at ${SRC}" >&2
            exit 3
            ;;
        error)
            rm -rf "${WORK}"
            die "read-version: could not fetch index at ${SRC} (${FETCH_ERROR})"
            ;;
    esac

    VERSION=$(adb_field "${ADB}" "${PKGNAME}" "version")
    rm -rf "${WORK}"
    [ -n "${VERSION}" ] || die "read-version: index at ${SRC} fetched OK but has no '${PKGNAME}' package -- unexpected feed shape, refusing to guess"
    echo "${VERSION}"
}

# =========================================================================
main() {
    [ $# -ge 1 ] || die "usage: feed-guard.sh <check-monotonic|plan-retention|verify-tree|read-version> ..."
    CMD="$1"; shift
    case "${CMD}" in
        check-monotonic) cmd_check_monotonic "$@" ;;
        plan-retention) cmd_plan_retention "$@" ;;
        verify-tree) cmd_verify_tree "$@" ;;
        read-version) cmd_read_version "$@" ;;
        *) die "unknown subcommand '${CMD}' (expected check-monotonic|plan-retention|verify-tree|read-version)" ;;
    esac
}

main "$@"
