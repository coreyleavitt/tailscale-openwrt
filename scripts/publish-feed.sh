#!/bin/sh
# scripts/publish-feed.sh
#
# S5a (RFC docs/rfc-apk-arch-coverage.md §5.4): cross-arch publish
# orchestration, factored out of the `publish-feed` workflow job for the
# same reason scripts/publish-arch.sh was extracted from that job and
# republish-feed (H6, rfc-apk-builds.md) -- an inline YAML loop isn't
# unit-testable; a script stubbable via env is. This wraps publish-arch.sh
# (the per-arch assemble+sign+guard+retain pipeline) with the THREE things
# that only make sense across the WHOLE arch set:
#
#   1. BOUNDED CONCURRENCY (TS_SIGN_CONCURRENCY, default 2). sign.leavitt.info
#      (imprimatur)'s safe concurrent-/sign/ec ceiling has never been
#      measured against the LIVE service -- that measurement is a
#      live-service spike this slice cannot run (RFC §5.4 round-2
#      B-SEV2/P-SEV2: thread-safety of the EC signer, Traefik pool limits,
#      any rate limit). N=2 (not N=1/serial) is the documented conservative
#      interim: publish-arch.sh's own per-arch isolation (per-arch ARCH_DIR,
#      per-invocation mktemp) is already verified safe for concurrent LOCAL
#      execution, and the failure mode the ~2-month outage actually taught
#      us (a /sign call that lies -- 200-shaped but wrong) is caught
#      per-call by publish-arch.sh's own H7 verify-before-publish gate plus
#      this script's retry/backoff, neither of which depends on running
#      serially. Bump TS_SIGN_CONCURRENCY once the real ceiling is measured
#      (a live spike against sign.leavitt.info) or a server-side semaphore
#      lands -- until then, treat 2 as a deliberately conservative default,
#      not a measured one.
#   2. PER-ARCH CHECKPOINT + bounded internal retry ROUNDS
#      (TS_PUBLISH_MAX_ROUNDS, default 3). Each round only (re-)dispatches
#      arches that are NOT already checkpointed: an arch whose
#      <pages-root>/apk/<arch>/packages.adb exists AND passes `adb-sign.py
#      verify` is skipped on the next round, so a transient failure on one
#      arch does not re-sign every other arch that already succeeded (RFC:
#      "a bare re-run re-signs all 30 is not acceptable at 30x"). Calling
#      `assemble` a SECOND time against the same pages-root (e.g. an
#      operator retry) gets the identical benefit for free -- the checkpoint
#      check has no notion of "this process" vs "a prior process".
#   3. ACCUMULATE-ALL reporting for `verify` (the post-publish integrity
#      walk): a bounded settle-retry per arch (to distinguish ordinary CDN
#      propagation lag from real corruption) BEFORE counting an arch as
#      failed, and the COMPLETE failing set reported to notify-alert.sh at
#      the end -- never `set -e` out on arch #3 and skip #4-30.
#
# S5b (RFC §5.4/§5.8, docs/rfc-apk-arch-coverage.handoff.md's "S5b-PREREQ"
# note) adds four more things on top of S5a's mechanics, all keyed off each
# row's `tier` field (core|extended):
#
#   4. PER-ARCH BOOTSTRAP-FORCE for `tier=="extended"`. A newly-widened
#      extended arch's very FIRST publish has no live index yet, so
#      feed-guard.sh check-monotonic's own bootstrap check hard-errors
#      ("no live index found at ...", needs --force) -- expected, not a real
#      problem. `--worker` detects exactly this failure signature and
#      retries ONLY that one arch with --force, scoped strictly to
#      tier=="extended" -- retiring the coarse global `force_publish=true`
#      interim the S5a handoff flagged (which would also force a genuinely
#      broken `core` arch past its monotonicity guard). A `core` arch
#      hitting the identical message is a real error (a live core arch's
#      index vanishing is never expected) and is left to fail normally.
#   5. CORE/EXTENDED ATOMICITY SPLIT (RFC §5.4 round-2 B-SEV1/P-SEV2,
#      revising round 1's flat "atomicity holds"). `assemble`'s final
#      accounting now splits by tier: a still-failing `core` arch after
#      TS_PUBLISH_MAX_ROUNDS is FATAL (die(), non-zero exit, BEFORE the
#      caller's subsequent Pages-deploy steps ever run -- core stays
#      all-or-nothing, production is never half-updated); a still-failing
#      `extended` arch is BEST-EFFORT -- logged loudly, its directory fully
#      removed from the tree (never a half-signed leftover from a late-stage
#      failure), and `assemble` still exits 0 with everything else that
#      succeeded. The single atomic `deploy-pages` step downstream is
#      unchanged -- only "which arches are in the tree it deploys" varies.
#   6. DEPUBLISH GUARD (RFC §5.4 round-2 B-SEV2). Before any signing work is
#      dispatched, `assemble` diffs the run's `tier=="core"` arch set
#      against the COMMITTED `tier=="core"` set in ARCHES_JSON_PATH (default:
#      the checked-out arches.json) and hard-fails if a committed core arch
#      is about to silently vanish from this run (bad merge, typo'd rename,
#      over-eager prune) -- unless every missing one is covered by an
#      explicit `--allow-depublish <arch>` (repeatable), for a deliberate
#      arch retirement (RFC §5.7 decommission runbook, S9).
#
# S7b (RFC §5.6/§Slices S7b) adds one more thing, purely informational:
#
#   7. UNVERIFIED-TIER PUBLISH LOG. Once the published-arch set for this run
#      is known (final accounting, after the core/extended split above),
#      `assemble` intersects it against `families.sh --unverified-arches`
#      (D1, reusing the SAME committed ARCHES_JSON_PATH the depublish guard
#      already reads -- the authoritative family/verify data, not just this
#      run's passed-in rows) and log()s exactly which published arches have
#      no CI-boot verify:true representative in their family -- they ship on
#      architectural certainty alone (S7a never qemu-verified them; S7b's own
#      named acceptance criterion: "coverage is never silently overstated").
#      Purely a log() -- NEVER changes assemble's exit status, and a run that
#      published only boot-verified arches gets a clean "all verified" line
#      instead of an empty/spurious warning.
#
# Usage:
#   publish-feed.sh assemble <arches-json> <built-apks-dir> <pages-root> \
#       [--force] [--allow-depublish <arch>]...
#   publish-feed.sh verify <arches-json> <pages-root> <base-url>
#   publish-feed.sh --worker <arch> <apk-file> <published-filename> <pages-root> \
#       [--force] [--tier <core|extended>]
#       (INTERNAL -- the bounded-concurrency fan-out re-invokes this script
#       as its own worker, since POSIX sh/dash cannot export a shell
#       function into a subprocess spawned by `xargs -P`. Not intended to be
#       called directly by a caller.)
#
# <arches-json> is a JSON array; each element may be a full arch object
# (carrying `.name`, same shape scripts/select-matrix.sh's publish_arches
# output produces) or a bare string -- `.name // .` handles both.
#
# Overridable via environment (mirrors publish-arch.sh's own convention;
# tests stub every one of these so the whole thing runs in milliseconds,
# no docker/network):
#   TS_SIGN_CONCURRENCY       bounded fan-out width for `assemble` (default 2
#                             -- see point 1 above)
#   TS_PUBLISH_MAX_ROUNDS     internal checkpoint/retry rounds for `assemble`
#                             (default 3)
#   TS_PUBLISH_ROUND_DELAY    seconds slept between rounds (default 3; tests
#                             set 0)
#   PUBLISH_ARCH_SH           path to publish-arch.sh (default:
#                             <repo-root>/scripts/publish-arch.sh)
#   ADB_SIGN_PY               path to adb-sign.py, used for the checkpoint's
#                             own verify call (default:
#                             <repo-root>/scripts/adb-sign.py) -- also
#                             forwarded to publish-arch.sh
#   PUBKEY_PATH               committed EC public key, used for the
#                             checkpoint's own verify call (default:
#                             <repo-root>/apk-signing.pem) -- also forwarded
#                             to publish-arch.sh
#   FEED_GUARD                path to feed-guard.sh, used by `verify`
#                             (default: <repo-root>/scripts/feed-guard.sh)
#   NOTIFY_ALERT              path to notify-alert.sh, used by `verify` on a
#                             non-empty failing set (default:
#                             <repo-root>/scripts/notify-alert.sh)
#   TS_VERIFY_SETTLE_RETRIES  bounded settle-retry attempts per arch before
#                             `verify` counts it as truly failed (default 5)
#   TS_VERIFY_SETTLE_DELAY    seconds between settle retries (default 3;
#                             tests set 0)
#   ARCHES_JSON_PATH          committed arch table the depublish guard reads
#                             tier=="core" names from, and (S7b) the table
#                             the unverified-tier publish log is computed
#                             against (default: <repo-root>/arches.json)
#   FAMILIES_SH               path to families.sh, used by the S7b
#                             unverified-tier publish log (default:
#                             <repo-root>/scripts/families.sh)
#   (publish-arch.sh's own APK_BIN/SIGN_URL/LIVE_BASE_URL/etc env overrides
#   pass through unchanged -- this script never shadows them.)
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
SELF="${SCRIPT_DIR}/publish-feed.sh"

die() {
    echo "publish-feed.sh: $1" >&2
    exit 1
}

PUBLISH_ARCH_SH="${PUBLISH_ARCH_SH:-${REPO_ROOT}/scripts/publish-arch.sh}"
ADB_SIGN_PY="${ADB_SIGN_PY:-${REPO_ROOT}/scripts/adb-sign.py}"
PUBKEY_PATH="${PUBKEY_PATH:-${REPO_ROOT}/apk-signing.pem}"
FEED_GUARD="${FEED_GUARD:-${REPO_ROOT}/scripts/feed-guard.sh}"
NOTIFY_ALERT="${NOTIFY_ALERT:-${REPO_ROOT}/scripts/notify-alert.sh}"
# S5b depublish guard (RFC §5.4 round-2 B-SEV2): the COMMITTED reference
# `assemble` diffs the run's core arch set against -- defaults to the real
# checked-out arches.json (the production case needs no wiring: CI already
# runs this script from a checkout that has it at the repo root). Tests
# point this at a small fixture instead.
ARCHES_JSON_PATH="${ARCHES_JSON_PATH:-${REPO_ROOT}/arches.json}"
# S7b (RFC §5.6/§Slices S7b): the unverified-tier publish log reuses
# families.sh's own `--unverified-arches` query (D1) rather than
# re-implementing family grouping here -- see cmd_assemble's final
# accounting.
FAMILIES_SH="${FAMILIES_SH:-${REPO_ROOT}/scripts/families.sh}"

[ -f "${PUBLISH_ARCH_SH}" ] || die "publish-arch.sh not found: ${PUBLISH_ARCH_SH}"

# is_checkpointed <arch> <pages-root> -- true (exit 0) iff this arch's
# packages.adb already exists AND cryptographically verifies. Shared by
# `assemble` (skip an already-done arch on the next round) and directly
# testable on its own via the internal --worker path's own checkpoint check.
is_checkpointed() {
    _arch="$1"; _pages_root="$2"
    _adb="${_pages_root}/apk/${_arch}/packages.adb"
    [ -f "${_adb}" ] || return 1
    python3 "${ADB_SIGN_PY}" verify "${_adb}" "${PUBKEY_PATH}" >/dev/null 2>&1
}

# =========================================================================
# --worker (internal): publish exactly one arch, honoring the checkpoint.
# =========================================================================
cmd_worker() {
    [ $# -ge 4 ] || die "--worker usage: --worker <arch> <apk-file> <published-filename> <pages-root> [--force] [--tier <tier>]"
    _arch="$1"; _apk_file="$2"; _published_name="$3"; _pages_root="$4"; shift 4
    _force_args=""
    _tier="core"
    while [ $# -gt 0 ]; do
        case "$1" in
            --force) _force_args="--force"; shift ;;
            --tier) _tier="$2"; shift 2 ;;
            *) die "--worker: unknown argument '$1'" ;;
        esac
    done

    if is_checkpointed "${_arch}" "${_pages_root}"; then
        echo "publish-feed.sh --worker: ${_arch} already checkpointed (packages.adb verifies) -- skipping re-sign"
        return 0
    fi

    if _out=$(sh "${PUBLISH_ARCH_SH}" "${_arch}" "${_apk_file}" "${_published_name}" "${_pages_root}" ${_force_args} 2>&1); then
        printf '%s\n' "${_out}"
        return 0
    fi
    _rc=$?
    printf '%s\n' "${_out}"

    # S5b bootstrap-force (RFC §5.4/§5.8 S5b-PREREQ): an `extended` arch's
    # very FIRST publish has no live index yet, so feed-guard.sh
    # check-monotonic's own "no live index" bootstrap check hard-errors
    # (needs --force) -- expected, not a real problem, for exactly the 26
    # newly-widened extended arches on their first-ever run. Rather than the
    # coarse global `force_publish=true` interim (which would also force-
    # downgrade a genuinely-broken `core` arch past its monotonicity guard),
    # detect THIS specific failure signature and retry ONLY this one arch
    # with --force -- scoped strictly to tier=="extended"; a `core` arch
    # hitting the identical message is a real error (a live core arch's
    # index vanishing is never expected) and is deliberately left to fail
    # through to the normal round/retry accounting untouched.
    if [ -z "${_force_args}" ] && [ "${_tier}" = "extended" ] \
        && printf '%s' "${_out}" | grep -q "no live index found at"; then
        echo "publish-feed.sh --worker: ${_arch} (tier=extended) has no live index yet -- auto-bootstrap-forcing this arch's first publish (RFC §5.4 S5b)"
        sh "${PUBLISH_ARCH_SH}" "${_arch}" "${_apk_file}" "${_published_name}" "${_pages_root}" --force
        return $?
    fi

    return "${_rc}"
}

# =========================================================================
# assemble
# =========================================================================
cmd_assemble() {
    [ $# -ge 3 ] || die "assemble usage: assemble <arches-json> <built-apks-dir> <pages-root> [--force] [--allow-depublish <arch>]..."
    _arches_json="$1"; _built_apks_dir="$2"; _pages_root="$3"; shift 3
    _force_args=""
    _allow_depublish=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --force) _force_args="--force"; shift ;;
            --allow-depublish)
                [ $# -ge 2 ] || die "assemble: --allow-depublish requires an <arch> argument"
                _allow_depublish="${_allow_depublish}$2 "
                shift 2
                ;;
            *) die "assemble: unknown argument '$1'" ;;
        esac
    done

    [ -d "${_built_apks_dir}" ] || die "assemble: built-apks dir not found: ${_built_apks_dir}"

    _concurrency="${TS_SIGN_CONCURRENCY:-2}"
    _max_rounds="${TS_PUBLISH_MAX_ROUNDS:-3}"
    _round_delay="${TS_PUBLISH_ROUND_DELAY:-3}"

    mkdir -p "${_pages_root}"

    _arch_names=$(echo "${_arches_json}" | jq -r '.[] | (.name // .)')
    [ -n "${_arch_names}" ] || die "assemble: empty arch list"

    # S5b depublish guard (RFC §5.4 round-2 B-SEV2): a `core` arch that is
    # committed (arches.json, ARCHES_JSON_PATH) but silently absent from
    # THIS run's arch set (bad merge, typo'd rename, over-eager prune) would
    # otherwise un-publish a live production arch the next time GH Pages
    # replaces the whole tree -- checked FIRST, before any signing work is
    # dispatched, so a structural mistake like this is caught cheaply rather
    # than after burning a full publish round on every other arch.
    [ -f "${ARCHES_JSON_PATH}" ] || die "assemble: committed arches.json not found at ${ARCHES_JSON_PATH} (set ARCHES_JSON_PATH)"
    _run_core=" $(echo "${_arches_json}" | jq -r '.[] | select((.tier // "core") == "core") | (.name // .)' | tr '\n' ' ')"
    _committed_core=$(jq -r '.[] | select(.tier == "core") | (.name // .)' "${ARCHES_JSON_PATH}")
    _missing_core=""
    for _c in ${_committed_core}; do
        case "${_run_core}" in
            *" ${_c} "*) ;;  # still present in this run -- fine
            *) _missing_core="${_missing_core}${_c} " ;;
        esac
    done
    if [ -n "${_missing_core}" ]; then
        _unallowed=""
        for _c in ${_missing_core}; do
            case " ${_allow_depublish} " in
                *" ${_c} "*)
                    echo "publish-feed.sh assemble: WARNING -- deliberately depublishing committed core arch '${_c}' (--allow-depublish given; RFC §5.4/§5.7 decommission runbook)" >&2
                    ;;
                *) _unallowed="${_unallowed}${_c} " ;;
            esac
        done
        [ -z "${_unallowed}" ] || die "assemble: committed core arch(es) missing from this run and NOT covered by --allow-depublish: ${_unallowed}-- refusing to silently depublish a live arch. If this is a deliberate retirement, pass --allow-depublish <arch> for each one."
    fi

    # Per-arch tier map ("<name> <tier>" lines, one per gated arch), read by
    # the xargs-spawned worker dispatch below to pass --tier through to
    # cmd_worker (S5b bootstrap-force keys off this). A row with no `tier`
    # field defaults to "core" -- the strictest/safest reading, so an input
    # that predates the tier field (or a bare-string arch list) gets the
    # conservative all-or-nothing treatment rather than silently becoming
    # best-effort.
    _tier_map=$(mktemp)
    echo "${_arches_json}" | jq -r '.[] | "\(.name // .) \(.tier // "core")"' > "${_tier_map}"

    _status_dir=$(mktemp -d)
    trap 'rm -rf "${_status_dir}" "${_tier_map}"' EXIT

    export STATUS_DIR="${_status_dir}"
    export BUILT_APKS_DIR="${_built_apks_dir}"
    export PAGES_ROOT_ARG="${_pages_root}"
    export FORCE_ARGS_ENV="${_force_args}"
    export TIER_MAP="${_tier_map}"
    export PUBLISH_ARCH_SH ADB_SIGN_PY PUBKEY_PATH SELF

    _round=1
    while [ "${_round}" -le "${_max_rounds}" ]; do
        _pending=""
        _pending_count=0
        for _arch in ${_arch_names}; do
            if ! is_checkpointed "${_arch}" "${_pages_root}"; then
                _pending="${_pending}${_arch}
"
                _pending_count=$((_pending_count + 1))
            fi
        done

        [ "${_pending_count}" -gt 0 ] || break

        echo "publish-feed.sh assemble: round ${_round}/${_max_rounds} -- dispatching ${_pending_count} arch(es) at concurrency ${_concurrency}"

        printf '%s' "${_pending}" | xargs -P "${_concurrency}" -I{} sh -c '
            set -eu
            arch="{}"
            apk_file=$(find "${BUILT_APKS_DIR}" -type f -path "*/${arch}/*.apk" 2>/dev/null | head -1)
            if [ -z "${apk_file}" ]; then
                echo "FAIL: no built .apk found for ${arch} under ${BUILT_APKS_DIR}" > "${STATUS_DIR}/${arch}.status"
                exit 0
            fi
            published_name=$(basename "${apk_file}")
            tier=$(awk -v a="${arch}" "\$1==a{print \$2; exit}" "${TIER_MAP}")
            [ -n "${tier}" ] || tier="core"
            if "${SELF}" --worker "${arch}" "${apk_file}" "${published_name}" "${PAGES_ROOT_ARG}" ${FORCE_ARGS_ENV} --tier "${tier}" \
                > "${STATUS_DIR}/${arch}.log" 2>&1; then
                echo "OK" > "${STATUS_DIR}/${arch}.status"
            else
                echo "FAIL (see ${STATUS_DIR}/${arch}.log)" > "${STATUS_DIR}/${arch}.status"
            fi
        '

        _round=$((_round + 1))
        if [ "${_round}" -le "${_max_rounds}" ]; then
            _still_pending=0
            for _arch in ${_arch_names}; do
                is_checkpointed "${_arch}" "${_pages_root}" || _still_pending=$((_still_pending + 1))
            done
            [ "${_still_pending}" -gt 0 ] && sleep "${_round_delay}"
        fi
    done

    # Final accounting: accumulate the COMPLETE failing set (never abort
    # mid-loop), then apply the S5b core/extended ATOMICITY SPLIT (RFC §5.4
    # round-2 B-SEV1/P-SEV2) -- a still-failing `core` arch is fatal (the
    # whole publish aborts, non-zero exit, BEFORE the caller's subsequent
    # Pages-deploy steps ever run -- production is never half-updated), but a
    # still-failing `extended` arch is best-effort: log it loudly, DROP it
    # from this publish (its directory is fully removed -- see below -- so a
    # partial/half-signed write from a late-stage failure, e.g. a rejected
    # monotonicity check after the .apk was already copied in, never lingers
    # in the tree that DOES get deployed), and let the deploy proceed with
    # everything else that succeeded.
    _failed_core=""
    _dropped_extended=""
    for _arch in ${_arch_names}; do
        if ! is_checkpointed "${_arch}" "${_pages_root}"; then
            _tier=$(awk -v a="${_arch}" '$1==a{print $2; exit}' "${_tier_map}")
            [ -n "${_tier}" ] || _tier="core"
            if [ "${_tier}" = "extended" ]; then
                echo "publish-feed.sh assemble: WARNING -- extended arch '${_arch}' still failing after ${_max_rounds} round(s); DROPPING it from this publish (best-effort, RFC §5.4) rather than aborting the whole deploy:" >&2
                [ -f "${_status_dir}/${_arch}.status" ] && echo "  ${_arch}: $(cat "${_status_dir}/${_arch}.status")" >&2
                rm -rf "${_pages_root}/apk/${_arch}"
                _dropped_extended="${_dropped_extended}${_arch} "
            else
                _failed_core="${_failed_core}${_arch} "
                if [ -f "${_status_dir}/${_arch}.status" ]; then
                    echo "publish-feed.sh assemble: ${_arch}: $(cat "${_status_dir}/${_arch}.status")" >&2
                fi
            fi
        fi
    done

    if [ -n "${_failed_core}" ]; then
        die "assemble: core arch(es) still failing after ${_max_rounds} round(s): ${_failed_core}-- core is all-or-nothing (RFC §5.4): aborting the ENTIRE publish before any deploy"
    fi

    if [ -n "${_dropped_extended}" ]; then
        echo "publish-feed.sh assemble: published with ${_dropped_extended}dropped (extended, best-effort) -- every core arch + every other extended arch succeeded"
    else
        echo "publish-feed.sh assemble: all $(echo "${_arch_names}" | grep -c .) arch(es) published successfully"
    fi

    # S7b (RFC §5.6/§Slices S7b): log() which of THIS RUN's actually-
    # published arches (arch_names minus whatever extended arches were just
    # dropped above -- a dropped arch's directory was rm -rf'd, so it was
    # never really published) are in the "unverified" tier: no CI-boot
    # verify:true representative anywhere in their family (D1's
    # families.sh --unverified-arches, against the SAME committed
    # ARCHES_JSON_PATH the depublish guard already consulted -- the
    # authoritative family/verify data, not just this run's passed-in rows).
    # Purely informational -- NEVER touches assemble's exit status. A
    # families.sh failure (e.g. a committed table that predates the S7b
    # schema) degrades to "nothing to report" rather than failing the
    # publish over an informational feature.
    _published_names=""
    for _arch in ${_arch_names}; do
        case " ${_dropped_extended}" in
            *" ${_arch} "*) ;;  # dropped this run -- never actually published
            *) _published_names="${_published_names}${_arch} " ;;
        esac
    done

    _unverified_tier=""
    if _u=$(sh "${FAMILIES_SH}" --unverified-arches "${ARCHES_JSON_PATH}" 2>/dev/null); then
        _unverified_tier="${_u}"
    fi
    _unverified_space=" "
    for _u in ${_unverified_tier}; do
        _unverified_space="${_unverified_space}${_u} "
    done

    _published_count=0
    _published_unverified=""
    _published_unverified_count=0
    for _arch in ${_published_names}; do
        _published_count=$((_published_count + 1))
        case "${_unverified_space}" in
            *" ${_arch} "*)
                _published_unverified="${_published_unverified}${_arch} "
                _published_unverified_count=$((_published_unverified_count + 1))
                ;;
        esac
    done

    if [ "${_published_unverified_count}" -gt 0 ]; then
        echo "publish-feed.sh assemble: ${_published_unverified_count} published arch(es) are in the S7b unverified tier (RFC §5.6/S7b) -- shipped on architectural certainty only, NOT CI-boot-verified: ${_published_unverified}"
    else
        echo "publish-feed.sh assemble: all ${_published_count} published arch(es) are CI-boot-verified (RFC §5.6/S7b) -- none shipped on architectural-certainty-only this run"
    fi
}

# =========================================================================
# verify (post-publish integrity walk: accumulate + settle)
# =========================================================================
cmd_verify() {
    [ $# -ge 3 ] || die "verify usage: verify <arches-json> <pages-root> <base-url>"
    _arches_json="$1"; _pages_root="$2"; _base_url="$3"

    [ -f "${FEED_GUARD}" ] || die "feed-guard.sh not found: ${FEED_GUARD}"

    _settle_retries="${TS_VERIFY_SETTLE_RETRIES:-5}"
    _settle_delay="${TS_VERIFY_SETTLE_DELAY:-3}"

    _arch_names=$(echo "${_arches_json}" | jq -r '.[] | (.name // .)')
    [ -n "${_arch_names}" ] || die "verify: empty arch list"

    _failed=""
    _failed_count=0

    for _arch in ${_arch_names}; do
        _attempt=1
        _ok=0
        _last_out=""
        # Bounded retry/settle BEFORE counting this arch as failed --
        # distinguishes ordinary CDN propagation lag (right after a fresh
        # Pages deploy) from real corruption (RFC §5.4 round-2 B-SEV3/P-SEV3).
        while [ "${_attempt}" -le "${_settle_retries}" ]; do
            if _last_out=$(sh "${FEED_GUARD}" verify-tree "${_pages_root}/apk/${_arch}" "${_base_url%/}/apk/${_arch}" 2>&1); then
                _ok=1
                echo "${_last_out}"
                break
            fi
            echo "publish-feed.sh verify: ${_arch} attempt ${_attempt}/${_settle_retries} failed -- settling before retry" >&2
            if [ "${_attempt}" -lt "${_settle_retries}" ]; then
                sleep "${_settle_delay}"
            fi
            _attempt=$((_attempt + 1))
        done

        if [ "${_ok}" -ne 1 ]; then
            echo "FAIL: ${_arch}: verify-tree did not pass after ${_settle_retries} attempt(s): ${_last_out}" >&2
            _failed="${_failed}${_arch} "
            _failed_count=$((_failed_count + 1))
        fi
        # NEVER short-circuit here -- accumulate across the WHOLE loop, not
        # just up to the first failure (RFC: "don't set -e out on arch #3
        # and never check #4-30").
    done

    if [ "${_failed_count}" -gt 0 ]; then
        if [ -x "${NOTIFY_ALERT}" ] || [ -f "${NOTIFY_ALERT}" ]; then
            sh "${NOTIFY_ALERT}" "publish-feed.sh verify: post-publish integrity check FAILED for ${_failed_count} arch(es): ${_failed}" \
                <<EOF
$(for _arch in ${_failed}; do echo "  - ${_arch}"; done)
EOF
        fi
        die "verify: ${_failed_count} arch(es) failed post-publish integrity verification: ${_failed}"
    fi

    echo "publish-feed.sh verify: all $(echo "${_arch_names}" | grep -c .) arch(es) passed post-publish integrity verification"
}

# =========================================================================
main() {
    [ $# -ge 1 ] || die "usage: publish-feed.sh <assemble|verify|--worker> ..."
    CMD="$1"; shift
    case "${CMD}" in
        assemble) cmd_assemble "$@" ;;
        verify) cmd_verify "$@" ;;
        --worker) cmd_worker "$@" ;;
        *) die "unknown subcommand '${CMD}' (expected assemble|verify|--worker)" ;;
    esac
}

main "$@"
