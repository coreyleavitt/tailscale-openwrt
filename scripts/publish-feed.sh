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
# core/extended ATOMICITY SPLIT (RFC §5.4 round-2 B-SEV1/P-SEV2) is
# DELIBERATELY NOT implemented here -- that is slice S5b. `assemble` stays
# all-or-nothing: if any arch is still unchecked-off after
# TS_PUBLISH_MAX_ROUNDS, `assemble` exits non-zero (same net effect as
# today's plain `set -eu` loop it replaces), so the workflow's subsequent
# Pages-deploy steps never run. Only the MECHANICS below are new -- the
# publish decision (all arches or none) is unchanged.
#
# Usage:
#   publish-feed.sh assemble <arches-json> <built-apks-dir> <pages-root> [--force]
#   publish-feed.sh verify <arches-json> <pages-root> <base-url>
#   publish-feed.sh --worker <arch> <apk-file> <published-filename> <pages-root> [--force]
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
    [ $# -ge 4 ] || die "--worker usage: --worker <arch> <apk-file> <published-filename> <pages-root> [--force]"
    _arch="$1"; _apk_file="$2"; _published_name="$3"; _pages_root="$4"; shift 4
    _force_args=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --force) _force_args="--force"; shift ;;
            *) die "--worker: unknown argument '$1'" ;;
        esac
    done

    if is_checkpointed "${_arch}" "${_pages_root}"; then
        echo "publish-feed.sh --worker: ${_arch} already checkpointed (packages.adb verifies) -- skipping re-sign"
        return 0
    fi

    sh "${PUBLISH_ARCH_SH}" "${_arch}" "${_apk_file}" "${_published_name}" "${_pages_root}" ${_force_args}
}

# =========================================================================
# assemble
# =========================================================================
cmd_assemble() {
    [ $# -ge 3 ] || die "assemble usage: assemble <arches-json> <built-apks-dir> <pages-root> [--force]"
    _arches_json="$1"; _built_apks_dir="$2"; _pages_root="$3"; shift 3
    _force_args=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --force) _force_args="--force"; shift ;;
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

    _status_dir=$(mktemp -d)
    trap 'rm -rf "${_status_dir}"' EXIT

    export STATUS_DIR="${_status_dir}"
    export BUILT_APKS_DIR="${_built_apks_dir}"
    export PAGES_ROOT_ARG="${_pages_root}"
    export FORCE_ARGS_ENV="${_force_args}"
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
            if "${SELF}" --worker "${arch}" "${apk_file}" "${published_name}" "${PAGES_ROOT_ARG}" ${FORCE_ARGS_ENV} \
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
    # mid-loop) -- see the header note on why this stays all-or-nothing at
    # this slice (S5b implements the core/extended split).
    _failed=""
    _failed_count=0
    for _arch in ${_arch_names}; do
        if ! is_checkpointed "${_arch}" "${_pages_root}"; then
            _failed="${_failed}${_arch} "
            _failed_count=$((_failed_count + 1))
            if [ -f "${_status_dir}/${_arch}.status" ]; then
                echo "publish-feed.sh assemble: ${_arch}: $(cat "${_status_dir}/${_arch}.status")" >&2
            fi
        fi
    done

    if [ "${_failed_count}" -gt 0 ]; then
        die "assemble: ${_failed_count} arch(es) still failing after ${_max_rounds} round(s): ${_failed}"
    fi

    echo "publish-feed.sh assemble: all $(echo "${_arch_names}" | grep -c .) arch(es) published successfully"
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
