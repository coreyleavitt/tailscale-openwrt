#!/bin/sh
# tests/apk/publish-feed.sh
#
# S5a test (RFC docs/rfc-apk-arch-coverage.md §5.4): scripts/publish-feed.sh
# is the extracted cross-arch publish orchestrator (bounded concurrency,
# per-arch checkpoint + retry rounds, accumulate-all post-publish verify) --
# mirrors tests/apk/publish-arch.sh's own stubbing style so this runs in a
# few seconds with no docker/network/real-imprimatur dependency. Every
# collaborator (publish-arch.sh, adb-sign.py, feed-guard.sh, notify-alert.sh)
# is stubbed via publish-feed.sh's own overridable env vars.
#
# Covers:
#   1. Usage/arg-handling errors.
#   2. `assemble` happy path: every arch published in round 1, packages.adb
#      written per arch.
#   3. Per-arch CHECKPOINT + internal retry ROUNDS: an arch that fails its
#      first attempt(s) is retried on a later round WITHOUT re-dispatching
#      arches that already succeeded (proven via a per-arch call-count log);
#      re-invoking `assemble` a SECOND time against the same pages-root
#      re-signs NOTHING (every arch already checkpointed).
#   4. Persistent per-arch failure: `assemble` exits non-zero after
#      exhausting TS_PUBLISH_MAX_ROUNDS, names the still-failing arch, and
#      (mechanics only, NOT the S5b atomicity split) other arches that DID
#      succeed are still checkpointed on disk.
#   5. TIMING ASSERTION (RFC §5.4 "promote the timing check ... to an S5a
#      deliverable"): N stubbed slow-signs under concurrency C take
#      meaningfully less wall-clock than N x latency -- proves the fan-out
#      actually overlaps sign round-trips, not just accepts a concurrency
#      argument cosmetically.
#   6. `verify`: accumulate + settle -- a transient per-arch failure
#      recovers within the bounded settle-retry window; MULTIPLE permanently
#      failing arches are ALL still attempted (never `set -e` out on the
#      first) and BOTH appear in the final failing set reported to
#      notify-alert.sh.
#
# Usage: sh tests/apk/publish-feed.sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
PUBLISH_FEED="${REPO_ROOT}/scripts/publish-feed.sh"

# shellcheck source=tests/apk/lib.sh
. "${SCRIPT_DIR}/lib.sh"

require_cmd jq
require_cmd python3
require_cmd xargs
require_cmd base64

if [ ! -f "${PUBLISH_FEED}" ]; then
    echo "FAIL: ${PUBLISH_FEED} not found" >&2
    exit 1
fi
if [ ! -x "${PUBLISH_FEED}" ]; then
    echo "FAIL: ${PUBLISH_FEED} exists but is not executable" >&2
    exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "${WORKDIR}"' EXIT

mkdir -p "${WORKDIR}/bin"

# ---------------------------------------------------------------------------
# fixtures: stub publish-arch.sh / adb-sign.py / feed-guard.sh / notify-alert.sh
# ---------------------------------------------------------------------------

# --- stub publish-arch.sh: writes a recognizable "signed" packages.adb for
# the given arch, logs every invocation (proves the checkpoint skip -- a
# checkpointed arch must NEVER appear in this log again), and can be told to
# fail an arch a bounded number of times (FAIL_COUNT_DIR/<arch> = remaining
# forced failures) or permanently (ALWAYS_FAIL_ARCHES, space-separated).
FAKE_PUBLISH_ARCH="${WORKDIR}/bin/fake-publish-arch.sh"
cat > "${FAKE_PUBLISH_ARCH}" <<'EOF'
#!/bin/sh
set -eu
ARCH="$1"; PAGES_ROOT="$4"; FORCE_FLAG="${5:-}"
echo "${ARCH}" >> "${CALL_LOG}"
[ -n "${FORCE_CALL_LOG:-}" ] && echo "${ARCH} ${FORCE_FLAG}" >> "${FORCE_CALL_LOG}"

if [ -n "${FAKE_PUBLISH_LATENCY:-}" ]; then
    sleep "${FAKE_PUBLISH_LATENCY}"
fi

# S5b bootstrap-force fixture: stands in for feed-guard.sh check-monotonic's
# real "no live index" hard-error (exit 2, needs --force) on a genuine
# first-ever publish -- fails with the SAME distinctive message real
# feed-guard.sh's die() uses ("no live index found at") unless --force is
# the exact 5th argument, in which case it proceeds as a normal first
# publish. Space-separated arch list, mirrors ALWAYS_FAIL_ARCHES's convention.
case " ${NO_LIVE_INDEX_ARCHES:-} " in
    *" ${ARCH} "*)
        if [ "${FORCE_FLAG}" != "--force" ]; then
            echo "publish-arch.sh: feed-guard.sh: check-monotonic: no live index found at https://apk.leavitt.dev/apk/${ARCH}/packages.adb (HTTP 404 or missing local file) -- refusing to auto-allow a 'first publish' on an untrusted feed host without confirmation" >&2
            exit 1
        fi
        ;;
esac

if [ -n "${FAIL_COUNT_DIR:-}" ] && [ -f "${FAIL_COUNT_DIR}/${ARCH}" ]; then
    N=$(cat "${FAIL_COUNT_DIR}/${ARCH}")
    if [ "${N}" -gt 0 ]; then
        N=$((N - 1))
        echo "${N}" > "${FAIL_COUNT_DIR}/${ARCH}"
        echo "fake-publish-arch: forced transient failure for ${ARCH} (${N} remaining)" >&2
        exit 1
    fi
fi

case " ${ALWAYS_FAIL_ARCHES:-} " in
    *" ${ARCH} "*)
        # Mimic the REAL publish-arch.sh's own sequencing: it cp's the .apk
        # into ARCH_DIR and starts mkndx BEFORE it can ever fail at a later
        # stage (sign/verify/monotonic) -- so a permanently-failing arch can
        # leave a partial (non-packages.adb) directory behind. Reproduced
        # here so the S5b "dropped extended arch is fully cleaned up, not
        # left as a half-write" assertion is a real proof, not a vacuous
        # pass because nothing was ever written.
        mkdir -p "${PAGES_ROOT}/apk/${ARCH}"
        printf 'PARTIAL-UNSIGNED-%s' "${ARCH}" > "${PAGES_ROOT}/apk/${ARCH}/unsigned.adb"
        echo "fake-publish-arch: forced PERMANENT failure for ${ARCH}" >&2
        exit 1
        ;;
esac

mkdir -p "${PAGES_ROOT}/apk/${ARCH}"
printf 'SIGNED-%s' "${ARCH}" > "${PAGES_ROOT}/apk/${ARCH}/packages.adb"
EOF
chmod +x "${FAKE_PUBLISH_ARCH}"

# --- stub adb-sign.py: only `verify` matters (publish-feed.sh's own
# checkpoint check calls it directly; the fake publish-arch.sh above never
# calls it since it's a full stand-in, not a wrapper around the real thing).
FAKE_ADB_SIGN="${WORKDIR}/bin/fake-adb-sign.py"
cat > "${FAKE_ADB_SIGN}" <<'EOF'
#!/usr/bin/env python3
import sys
cmd = sys.argv[1]
if cmd == "verify":
    signed = sys.argv[2]
    with open(signed, "rb") as f:
        data = f.read()
    sys.exit(0 if data.startswith(b"SIGNED-") else 1)
else:
    print(f"fake-adb-sign.py: unexpected subcommand {cmd}", file=sys.stderr)
    sys.exit(2)
EOF
chmod +x "${FAKE_ADB_SIGN}"

# --- stub feed-guard.sh: only `verify-tree` matters here. Same bounded
# transient-failure / permanent-failure convention as fake-publish-arch.sh
# above, keyed by the tree dir's own basename (the arch).
FAKE_FEED_GUARD="${WORKDIR}/bin/fake-feed-guard.sh"
cat > "${FAKE_FEED_GUARD}" <<'EOF'
#!/bin/sh
set -eu
cmd="$1"; shift
case "${cmd}" in
    verify-tree)
        tree_dir="$1"
        arch=$(basename "${tree_dir}")
        echo "${arch}" >> "${VERIFY_CALL_LOG}"

        if [ -n "${VERIFY_FAIL_COUNT_DIR:-}" ] && [ -f "${VERIFY_FAIL_COUNT_DIR}/${arch}" ]; then
            n=$(cat "${VERIFY_FAIL_COUNT_DIR}/${arch}")
            if [ "${n}" -gt 0 ]; then
                n=$((n - 1))
                echo "${n}" > "${VERIFY_FAIL_COUNT_DIR}/${arch}"
                echo "FAIL: forced transient settle failure for ${arch}" >&2
                exit 1
            fi
        fi

        case " ${VERIFY_ALWAYS_FAIL_ARCHES:-} " in
            *" ${arch} "*)
                echo "FAIL: forced PERMANENT failure for ${arch}" >&2
                exit 1
                ;;
        esac

        echo "OK: verify-tree passed for ${arch}"
        ;;
    *)
        echo "fake-feed-guard: unknown subcommand ${cmd}" >&2
        exit 9
        ;;
esac
EOF
chmod +x "${FAKE_FEED_GUARD}"

# --- stub notify-alert.sh: logs the message + stdin details verbatim.
FAKE_NOTIFY_ALERT="${WORKDIR}/bin/fake-notify-alert.sh"
cat > "${FAKE_NOTIFY_ALERT}" <<'EOF'
#!/bin/sh
{
    echo "MESSAGE: $1"
    if [ ! -t 0 ]; then
        echo "DETAILS:"
        cat
    fi
} >> "${NOTIFY_LOG}"
exit 0
EOF
chmod +x "${FAKE_NOTIFY_ALERT}"

# Common env for every stubbed invocation below.
export PUBLISH_ARCH_SH="${FAKE_PUBLISH_ARCH}"
export ADB_SIGN_PY="${FAKE_ADB_SIGN}"
export FEED_GUARD="${FAKE_FEED_GUARD}"
export NOTIFY_ALERT="${FAKE_NOTIFY_ALERT}"
export PUBKEY_PATH="${WORKDIR}/pub.pem"
printf -- '-----BEGIN PUBLIC KEY-----\nDUMMY\n-----END PUBLIC KEY-----\n' > "${PUBKEY_PATH}"
# Fast by default -- individual tests override where the round/settle COUNT
# or DELAY itself is what's being asserted.
export TS_PUBLISH_ROUND_DELAY=0
export TS_VERIFY_SETTLE_DELAY=0

# S5b depublish guard (RFC §5.4 round-2 B-SEV2): `assemble` diffs the run's
# core arch-name set against a COMMITTED reference (the real arches.json in
# production, default ARCHES_JSON_PATH) and hard-fails if a committed core
# arch is about to silently vanish. Default here is an EMPTY committed set
# (nothing to diff against -> the guard is inert) so every pre-existing test
# below, none of which is about the depublish guard, is unaffected by its
# introduction. Only section 9 (and any other test that cares) sets
# ARCHES_JSON_PATH to a fixture with real entries via committed_core_json
# below, to actually exercise the guard.
DEFAULT_ARCHES_JSON_PATH="${WORKDIR}/arches-committed-default.json"
echo '[]' > "${DEFAULT_ARCHES_JSON_PATH}"
export ARCHES_JSON_PATH="${DEFAULT_ARCHES_JSON_PATH}"

committed_core_json() {
    # committed_core_json <arch...> -> writes an arches.json-shaped fixture
    # (every given name at tier=="core") to a fresh temp file under WORKDIR
    # and prints its path, for a test that wants the S5b depublish guard to
    # see a REAL (non-empty) committed core set -- e.g. to assert the guard
    # is a no-op when the run exactly covers it.
    _f=$(mktemp "${WORKDIR}/committed-core-XXXXXX.json")
    _json="["
    _first=1
    for _a in "$@"; do
        [ "${_first}" -eq 1 ] || _json="${_json},"
        _json="${_json}{\"name\":\"${_a}\",\"tier\":\"core\"}"
        _first=0
    done
    echo "${_json}]" > "${_f}"
    echo "${_f}"
}

mk_built_apks() {
    # mk_built_apks <dir> <arch...> -- lay out the S5a per-family artifact
    # shape (one arch subdir per gated arch; family grouping is irrelevant to
    # publish-feed.sh, which only searches for a `<arch>/*.apk` path segment).
    _dir="$1"; shift
    for _a in "$@"; do
        mkdir -p "${_dir}/apk-family-x/${_a}"
        printf 'DUMMY-APK' > "${_dir}/apk-family-x/${_a}/tailscale-1.0-r1-${_a}.apk"
    done
}

arches_json() {
    # arches_json <arch[:tier]...> -> a JSON array of {"name","tier"}
    # objects, the same shape select-matrix.sh's publish_arches output
    # produces (S5b: tier now carried through -- defaults to "core" when a
    # bare name with no ":tier" suffix is given, so every pre-S5b test in
    # this file that never mentions tier keeps its old strict/conservative
    # all-or-nothing behavior unchanged).
    _json="["
    _first=1
    for _a in "$@"; do
        _name="${_a%%:*}"
        case "${_a}" in
            *:*) _tier="${_a#*:}" ;;
            *) _tier="core" ;;
        esac
        [ "${_first}" -eq 1 ] || _json="${_json},"
        _json="${_json}{\"name\":\"${_name}\",\"tier\":\"${_tier}\"}"
        _first=0
    done
    echo "${_json}]"
}

# ===========================================================================
# 1. usage / arg-handling errors
# ===========================================================================
echo "=== 1. usage / arg-handling errors ==="

RC=0
"${PUBLISH_FEED}" >/dev/null 2>"${WORKDIR}/no-args.log" || RC=$?
assert_eq "no args: exit non-zero" "true" "$([ "${RC}" -ne 0 ] && echo true || echo false)"
assert_contains "no args: usage message" "$(cat "${WORKDIR}/no-args.log")" "usage"

RC=0
"${PUBLISH_FEED}" bogus-command >/dev/null 2>"${WORKDIR}/bad-cmd.log" || RC=$?
assert_eq "unknown subcommand: exit non-zero" "true" "$([ "${RC}" -ne 0 ] && echo true || echo false)"
assert_contains "unknown subcommand: names it" "$(cat "${WORKDIR}/bad-cmd.log")" "unknown subcommand"

RC=0
"${PUBLISH_FEED}" assemble >/dev/null 2>"${WORKDIR}/assemble-noargs.log" || RC=$?
assert_eq "assemble with no args: exit non-zero" "true" "$([ "${RC}" -ne 0 ] && echo true || echo false)"

RC=0
"${PUBLISH_FEED}" verify >/dev/null 2>"${WORKDIR}/verify-noargs.log" || RC=$?
assert_eq "verify with no args: exit non-zero" "true" "$([ "${RC}" -ne 0 ] && echo true || echo false)"

echo

# ===========================================================================
# 2. assemble happy path -- every arch published in round 1
# ===========================================================================
echo "=== 2. assemble: happy path (3 arches, all succeed first try) ==="

BUILT_APKS_2="${WORKDIR}/built-apks-2"
PAGES_ROOT_2="${WORKDIR}/pages-root-2"
CALL_LOG_2="${WORKDIR}/call-log-2"
: > "${CALL_LOG_2}"
mk_built_apks "${BUILT_APKS_2}" arch-a arch-b arch-c

RC=0
CALL_LOG="${CALL_LOG_2}" TS_SIGN_CONCURRENCY=2 \
    "${PUBLISH_FEED}" assemble "$(arches_json arch-a arch-b arch-c)" "${BUILT_APKS_2}" "${PAGES_ROOT_2}" \
    >"${WORKDIR}/assemble-happy.log" 2>&1 || RC=$?
assert_eq "happy path: assemble exits 0" "0" "${RC}"

for a in arch-a arch-b arch-c; do
    assert_eq "happy path: ${a}/packages.adb written" "true" \
        "$([ -f "${PAGES_ROOT_2}/apk/${a}/packages.adb" ] && echo true || echo false)"
done

CALL_COUNT_2=$(sort "${CALL_LOG_2}" | uniq -c | awk '{print $1}' | sort -u | tr '\n' ' ')
assert_eq "happy path: every arch dispatched exactly once" "1 " "${CALL_COUNT_2}"

echo

# ===========================================================================
# 3. per-arch checkpoint + internal retry rounds
# ===========================================================================
echo "=== 3. checkpoint + retry rounds: a transient failure is retried WITHOUT re-dispatching already-done arches ==="

BUILT_APKS_3="${WORKDIR}/built-apks-3"
PAGES_ROOT_3="${WORKDIR}/pages-root-3"
CALL_LOG_3="${WORKDIR}/call-log-3"
FAIL_COUNT_DIR_3="${WORKDIR}/fail-count-3"
: > "${CALL_LOG_3}"
mkdir -p "${FAIL_COUNT_DIR_3}"
mk_built_apks "${BUILT_APKS_3}" arch-a arch-b arch-c

# arch-b fails its first attempt, then succeeds on round 2.
echo 1 > "${FAIL_COUNT_DIR_3}/arch-b"

RC=0
CALL_LOG="${CALL_LOG_3}" FAIL_COUNT_DIR="${FAIL_COUNT_DIR_3}" TS_SIGN_CONCURRENCY=2 TS_PUBLISH_MAX_ROUNDS=3 \
    "${PUBLISH_FEED}" assemble "$(arches_json arch-a arch-b arch-c)" "${BUILT_APKS_3}" "${PAGES_ROOT_3}" \
    >"${WORKDIR}/assemble-retry.log" 2>&1 || RC=$?
assert_eq "retry rounds: assemble still succeeds overall (arch-b recovered)" "0" "${RC}"

for a in arch-a arch-b arch-c; do
    assert_eq "retry rounds: ${a}/packages.adb written" "true" \
        "$([ -f "${PAGES_ROOT_3}/apk/${a}/packages.adb" ] && echo true || echo false)"
done

ARCH_A_CALLS=$(grep -c '^arch-a$' "${CALL_LOG_3}")
ARCH_B_CALLS=$(grep -c '^arch-b$' "${CALL_LOG_3}")
ARCH_C_CALLS=$(grep -c '^arch-c$' "${CALL_LOG_3}")
assert_eq "retry rounds: arch-a (never failed) dispatched exactly ONCE, not re-signed for arch-b's retry" "1" "${ARCH_A_CALLS}"
assert_eq "retry rounds: arch-c (never failed) dispatched exactly ONCE" "1" "${ARCH_C_CALLS}"
assert_eq "retry rounds: arch-b (failed once) dispatched exactly TWICE (1 failure + 1 success)" "2" "${ARCH_B_CALLS}"

echo

echo "=== 3b. re-invoking assemble a SECOND time against the same pages-root re-signs NOTHING ==="

: > "${CALL_LOG_3}"
RC=0
CALL_LOG="${CALL_LOG_3}" FAIL_COUNT_DIR="${FAIL_COUNT_DIR_3}" TS_SIGN_CONCURRENCY=2 TS_PUBLISH_MAX_ROUNDS=3 \
    "${PUBLISH_FEED}" assemble "$(arches_json arch-a arch-b arch-c)" "${BUILT_APKS_3}" "${PAGES_ROOT_3}" \
    >"${WORKDIR}/assemble-reinvoke.log" 2>&1 || RC=$?
assert_eq "re-invocation: still exits 0 (everything already checkpointed)" "0" "${RC}"
assert_eq "re-invocation: publish-arch.sh (stub) was NOT called for ANY arch -- all 3 were already checkpointed" "" \
    "$(cat "${CALL_LOG_3}")"

echo

# ===========================================================================
# 4. persistent per-arch failure -- exhausts rounds, names the arch, but
#    other arches are still checkpointed (mechanics only -- S5b implements
#    the actual core/extended atomicity split on top of this)
# ===========================================================================
echo "=== 4. persistent failure: assemble exits non-zero after exhausting rounds, names the arch ==="

BUILT_APKS_4="${WORKDIR}/built-apks-4"
PAGES_ROOT_4="${WORKDIR}/pages-root-4"
CALL_LOG_4="${WORKDIR}/call-log-4"
: > "${CALL_LOG_4}"
mk_built_apks "${BUILT_APKS_4}" arch-a arch-b arch-c

RC=0
CALL_LOG="${CALL_LOG_4}" ALWAYS_FAIL_ARCHES="arch-b" TS_SIGN_CONCURRENCY=2 TS_PUBLISH_MAX_ROUNDS=2 \
    "${PUBLISH_FEED}" assemble "$(arches_json arch-a arch-b arch-c)" "${BUILT_APKS_4}" "${PAGES_ROOT_4}" \
    >"${WORKDIR}/assemble-persistent.log" 2>&1 || RC=$?
assert_eq "persistent failure: assemble exits non-zero" "true" "$([ "${RC}" -ne 0 ] && echo true || echo false)"
assert_contains "persistent failure: names the still-failing arch" \
    "$(cat "${WORKDIR}/assemble-persistent.log")" "arch-b"
assert_contains "persistent failure: mentions the round count exhausted" \
    "$(cat "${WORKDIR}/assemble-persistent.log")" "2 round(s)"

assert_eq "persistent failure: arch-a (unaffected) still got checkpointed on disk" "true" \
    "$([ -f "${PAGES_ROOT_4}/apk/arch-a/packages.adb" ] && echo true || echo false)"
assert_eq "persistent failure: arch-c (unaffected) still got checkpointed on disk" "true" \
    "$([ -f "${PAGES_ROOT_4}/apk/arch-c/packages.adb" ] && echo true || echo false)"
assert_eq "persistent failure: arch-b (permanently failing) never got a packages.adb" "false" \
    "$([ -f "${PAGES_ROOT_4}/apk/arch-b/packages.adb" ] && echo true || echo false)"

ARCH_B_CALLS_4=$(grep -c '^arch-b$' "${CALL_LOG_4}")
assert_eq "persistent failure: arch-b was retried exactly TS_PUBLISH_MAX_ROUNDS (2) times, not forever" "2" "${ARCH_B_CALLS_4}"

echo

# ===========================================================================
# 5. TIMING ASSERTION: concurrency actually overlaps sign round-trips
# ===========================================================================
echo "=== 5. timing: N stubbed slow-signs under concurrency C beat N x latency ==="

BUILT_APKS_5="${WORKDIR}/built-apks-5"
PAGES_ROOT_5="${WORKDIR}/pages-root-5"
CALL_LOG_5="${WORKDIR}/call-log-5"
: > "${CALL_LOG_5}"
mk_built_apks "${BUILT_APKS_5}" t-a t-b t-c t-d

LATENCY=1
START=$(date +%s)
CALL_LOG="${CALL_LOG_5}" FAKE_PUBLISH_LATENCY="${LATENCY}" TS_SIGN_CONCURRENCY=4 TS_PUBLISH_MAX_ROUNDS=1 \
    "${PUBLISH_FEED}" assemble "$(arches_json t-a t-b t-c t-d)" "${BUILT_APKS_5}" "${PAGES_ROOT_5}" \
    >"${WORKDIR}/assemble-timing.log" 2>&1
END=$(date +%s)
ELAPSED=$((END - START))

log_info "timing: 4 arches x ${LATENCY}s latency at concurrency 4 took ${ELAPSED}s wall-clock (serial would be ~4s)"
assert_eq "timing: wall-clock is well under N x latency (4s) -- fan-out actually overlaps, not serial" "true" \
    "$([ "${ELAPSED}" -lt 3 ] && echo true || echo false)"
assert_eq "timing: wall-clock is still at least ~1 latency (not a no-op/instant no-sleep stub)" "true" \
    "$([ "${ELAPSED}" -ge 1 ] && echo true || echo false)"

echo

# ===========================================================================
# 6. verify: accumulate + settle
# ===========================================================================
echo "=== 6. verify: a transient failure settles/recovers within the retry window ==="

PAGES_ROOT_V1="${WORKDIR}/pages-root-v1"
VERIFY_CALL_LOG_1="${WORKDIR}/verify-call-log-1"
VERIFY_FAIL_DIR_1="${WORKDIR}/verify-fail-1"
NOTIFY_LOG_1="${WORKDIR}/notify-1.log"
: > "${VERIFY_CALL_LOG_1}"
: > "${NOTIFY_LOG_1}"
mkdir -p "${VERIFY_FAIL_DIR_1}" "${PAGES_ROOT_V1}/apk/v-a" "${PAGES_ROOT_V1}/apk/v-b"
echo 2 > "${VERIFY_FAIL_DIR_1}/v-b"

RC=0
VERIFY_CALL_LOG="${VERIFY_CALL_LOG_1}" VERIFY_FAIL_COUNT_DIR="${VERIFY_FAIL_DIR_1}" NOTIFY_LOG="${NOTIFY_LOG_1}" \
    TS_VERIFY_SETTLE_RETRIES=5 \
    "${PUBLISH_FEED}" verify "$(arches_json v-a v-b)" "${PAGES_ROOT_V1}" "http://example.invalid" \
    >"${WORKDIR}/verify-settle.log" 2>&1 || RC=$?
assert_eq "settle: verify exits 0 overall (v-b recovered within the settle window)" "0" "${RC}"
V_B_ATTEMPTS=$(grep -c '^v-b$' "${VERIFY_CALL_LOG_1}")
assert_eq "settle: v-b was attempted 3 times (2 failures + 1 success), proving real retry" "3" "${V_B_ATTEMPTS}"
assert_eq "settle: notify-alert.sh was NOT invoked (nothing ultimately failed)" "" \
    "$(cat "${NOTIFY_LOG_1}")"

echo

echo "=== 6b. verify: MULTIPLE permanent failures are ALL attempted and BOTH reported (accumulate-all) ==="

PAGES_ROOT_V2="${WORKDIR}/pages-root-v2"
VERIFY_CALL_LOG_2="${WORKDIR}/verify-call-log-2"
NOTIFY_LOG_2="${WORKDIR}/notify-2.log"
: > "${VERIFY_CALL_LOG_2}"
: > "${NOTIFY_LOG_2}"
mkdir -p "${PAGES_ROOT_V2}/apk/v-a" "${PAGES_ROOT_V2}/apk/v-b" "${PAGES_ROOT_V2}/apk/v-c" "${PAGES_ROOT_V2}/apk/v-d"

RC=0
VERIFY_CALL_LOG="${VERIFY_CALL_LOG_2}" VERIFY_ALWAYS_FAIL_ARCHES="v-b v-d" NOTIFY_LOG="${NOTIFY_LOG_2}" \
    TS_VERIFY_SETTLE_RETRIES=2 \
    "${PUBLISH_FEED}" verify "$(arches_json v-a v-b v-c v-d)" "${PAGES_ROOT_V2}" "http://example.invalid" \
    >"${WORKDIR}/verify-accumulate.log" 2>&1 || RC=$?
assert_eq "accumulate-all: verify exits non-zero" "true" "$([ "${RC}" -ne 0 ] && echo true || echo false)"

# THE key accumulate-all proof: v-a and v-c (which come AFTER v-b in arch
# order for v-c, and v-d comes after both) must still have been attempted --
# a `set -e`-out-on-first-failure implementation would never reach v-c/v-d.
assert_contains "accumulate-all: v-a (before the first failure) was checked" \
    "$(cat "${VERIFY_CALL_LOG_2}")" "v-a"
assert_contains "accumulate-all: v-c (BETWEEN the two failing arches) was still checked" \
    "$(cat "${VERIFY_CALL_LOG_2}")" "v-c"
assert_contains "accumulate-all: v-d (AFTER the first failure) was still checked -- proves no early set -e exit" \
    "$(cat "${VERIFY_CALL_LOG_2}")" "v-d"

assert_contains "accumulate-all: final error names v-b" "$(cat "${WORKDIR}/verify-accumulate.log")" "v-b"
assert_contains "accumulate-all: final error names v-d TOO (complete failing set, not just the first)" \
    "$(cat "${WORKDIR}/verify-accumulate.log")" "v-d"

assert_contains "accumulate-all: notify-alert.sh WAS invoked" "$(cat "${NOTIFY_LOG_2}")" "MESSAGE:"
assert_contains "accumulate-all: notify-alert.sh's message names v-b" "$(cat "${NOTIFY_LOG_2}")" "v-b"
assert_contains "accumulate-all: notify-alert.sh's message names v-d TOO" "$(cat "${NOTIFY_LOG_2}")" "v-d"

# ===========================================================================
# 7. S5b: per-arch bootstrap-force via tier=="extended" (RFC §5.4/§5b-prereq)
# ===========================================================================
echo "=== 7. S5b: extended arch auto-bootstrap-forces on a genuine first publish (no live index); core does NOT ==="

BUILT_APKS_7="${WORKDIR}/built-apks-7"
PAGES_ROOT_7="${WORKDIR}/pages-root-7"
CALL_LOG_7="${WORKDIR}/call-log-7"
FORCE_CALL_LOG_7="${WORKDIR}/force-call-log-7"
: > "${CALL_LOG_7}"
: > "${FORCE_CALL_LOG_7}"
mk_built_apks "${BUILT_APKS_7}" ext-new core-new

RC=0
CALL_LOG="${CALL_LOG_7}" FORCE_CALL_LOG="${FORCE_CALL_LOG_7}" NO_LIVE_INDEX_ARCHES="ext-new core-new" \
    TS_SIGN_CONCURRENCY=2 TS_PUBLISH_MAX_ROUNDS=1 \
    "${PUBLISH_FEED}" assemble "$(arches_json ext-new:extended core-new:core)" "${BUILT_APKS_7}" "${PAGES_ROOT_7}" \
    >"${WORKDIR}/assemble-bootstrap.log" 2>&1 || RC=$?

# core-new never gets auto-forced -- a missing core live-index is a real
# error, so it stays failed after the single round and (pre-S5b atomicity
# split, still all-or-nothing at this point) the whole assemble call fails.
assert_eq "bootstrap-force: overall assemble still fails (core-new never bootstrapped)" "true" \
    "$([ "${RC}" -ne 0 ] && echo true || echo false)"

assert_eq "bootstrap-force: extended arch's packages.adb WAS written (auto-bootstrapped)" "true" \
    "$([ -f "${PAGES_ROOT_7}/apk/ext-new/packages.adb" ] && echo true || echo false)"
assert_eq "bootstrap-force: core arch's packages.adb was NEVER written (no auto-force for core)" "false" \
    "$([ -f "${PAGES_ROOT_7}/apk/core-new/packages.adb" ] && echo true || echo false)"

EXT_CALLS_7=$(grep -c '^ext-new$' "${CALL_LOG_7}")
CORE_CALLS_7=$(grep -c '^core-new$' "${CALL_LOG_7}")
assert_eq "bootstrap-force: ext-new invoked TWICE (1 no-force failure + 1 auto-forced success)" "2" "${EXT_CALLS_7}"
assert_eq "bootstrap-force: core-new invoked ONCE (no auto-retry attempted for core)" "1" "${CORE_CALLS_7}"

assert_contains "bootstrap-force: ext-new's first attempt had NO --force" "$(cat "${FORCE_CALL_LOG_7}")" "ext-new "
assert_contains "bootstrap-force: ext-new's second attempt WAS auto-forced" "$(cat "${FORCE_CALL_LOG_7}")" "ext-new --force"
assert_not_contains "bootstrap-force: core-new was NEVER auto-forced (tier scoping proof)" \
    "$(cat "${FORCE_CALL_LOG_7}")" "core-new --force"

echo

# ===========================================================================
# 8. S5b: core/extended atomicity split (RFC §5.4 round-2 B-SEV1/P-SEV2)
# ===========================================================================
echo "=== 8a. atomicity split: a failing CORE arch aborts the WHOLE assemble (non-zero), even with healthy extended arches ==="

BUILT_APKS_8A="${WORKDIR}/built-apks-8a"
PAGES_ROOT_8A="${WORKDIR}/pages-root-8a"
CALL_LOG_8A="${WORKDIR}/call-log-8a"
: > "${CALL_LOG_8A}"
mk_built_apks "${BUILT_APKS_8A}" core-bad core-good ext-good

RC=0
CALL_LOG="${CALL_LOG_8A}" ALWAYS_FAIL_ARCHES="core-bad" TS_SIGN_CONCURRENCY=2 TS_PUBLISH_MAX_ROUNDS=2 \
    "${PUBLISH_FEED}" assemble \
    "$(arches_json core-bad:core core-good:core ext-good:extended)" "${BUILT_APKS_8A}" "${PAGES_ROOT_8A}" \
    >"${WORKDIR}/assemble-8a.log" 2>&1 || RC=$?

assert_eq "8a: a failing core arch aborts the ENTIRE assemble (non-zero exit)" "true" \
    "$([ "${RC}" -ne 0 ] && echo true || echo false)"
assert_contains "8a: names the failing core arch" "$(cat "${WORKDIR}/assemble-8a.log")" "core-bad"
assert_eq "8a: the failing core arch never got a packages.adb" "false" \
    "$([ -f "${PAGES_ROOT_8A}/apk/core-bad/packages.adb" ] && echo true || echo false)"
assert_eq "8a: the OTHER (healthy) core arch still succeeded on disk" "true" \
    "$([ -f "${PAGES_ROOT_8A}/apk/core-good/packages.adb" ] && echo true || echo false)"
assert_eq "8a: the healthy extended arch also still succeeded on disk (core failure doesn't roll back others)" "true" \
    "$([ -f "${PAGES_ROOT_8A}/apk/ext-good/packages.adb" ] && echo true || echo false)"

echo

echo "=== 8b. atomicity split: a failing EXTENDED arch is dropped (best-effort) -- assemble still exits 0 ==="

BUILT_APKS_8B="${WORKDIR}/built-apks-8b"
PAGES_ROOT_8B="${WORKDIR}/pages-root-8b"
CALL_LOG_8B="${WORKDIR}/call-log-8b"
: > "${CALL_LOG_8B}"
mk_built_apks "${BUILT_APKS_8B}" core-ok ext-ok ext-bad

RC=0
CALL_LOG="${CALL_LOG_8B}" ALWAYS_FAIL_ARCHES="ext-bad" TS_SIGN_CONCURRENCY=2 TS_PUBLISH_MAX_ROUNDS=2 \
    "${PUBLISH_FEED}" assemble \
    "$(arches_json core-ok:core ext-ok:extended ext-bad:extended)" "${BUILT_APKS_8B}" "${PAGES_ROOT_8B}" \
    >"${WORKDIR}/assemble-8b.log" 2>&1 || RC=$?

assert_eq "8b: a failing EXTENDED arch does NOT abort the deploy (assemble exits 0)" "0" "${RC}"
assert_contains "8b: loudly logs the dropped extended arch" "$(cat "${WORKDIR}/assemble-8b.log")" "ext-bad"
assert_eq "8b: the failed extended arch's directory is fully ABSENT from the tree (clean drop, not a half-write)" "false" \
    "$([ -d "${PAGES_ROOT_8B}/apk/ext-bad" ] && echo true || echo false)"
assert_eq "8b: core arch present" "true" \
    "$([ -f "${PAGES_ROOT_8B}/apk/core-ok/packages.adb" ] && echo true || echo false)"
assert_eq "8b: the OTHER (healthy) extended arch is present" "true" \
    "$([ -f "${PAGES_ROOT_8B}/apk/ext-ok/packages.adb" ] && echo true || echo false)"

echo

echo "=== 8c. atomicity split: core + all healthy extended succeed -> full tree, exit 0 ==="

BUILT_APKS_8C="${WORKDIR}/built-apks-8c"
PAGES_ROOT_8C="${WORKDIR}/pages-root-8c"
CALL_LOG_8C="${WORKDIR}/call-log-8c"
: > "${CALL_LOG_8C}"
mk_built_apks "${BUILT_APKS_8C}" core-1 core-2 ext-1 ext-2

RC=0
CALL_LOG="${CALL_LOG_8C}" TS_SIGN_CONCURRENCY=2 \
    "${PUBLISH_FEED}" assemble \
    "$(arches_json core-1:core core-2:core ext-1:extended ext-2:extended)" "${BUILT_APKS_8C}" "${PAGES_ROOT_8C}" \
    >"${WORKDIR}/assemble-8c.log" 2>&1 || RC=$?

assert_eq "8c: full success -> exit 0" "0" "${RC}"
for a in core-1 core-2 ext-1 ext-2; do
    assert_eq "8c: ${a} present in the assembled tree" "true" \
        "$([ -f "${PAGES_ROOT_8C}/apk/${a}/packages.adb" ] && echo true || echo false)"
done

echo

# ===========================================================================
# 9. S5b: depublish guard (RFC §5.4 round-2 B-SEV2)
# ===========================================================================
echo "=== 9. depublish guard: a committed core arch silently missing from the run hard-fails; --allow-depublish overrides it ==="

BUILT_APKS_9="${WORKDIR}/built-apks-9"
PAGES_ROOT_9A="${WORKDIR}/pages-root-9a"
CALL_LOG_9A="${WORKDIR}/call-log-9a"
: > "${CALL_LOG_9A}"
mk_built_apks "${BUILT_APKS_9}" dep-a

# Committed reference: dep-a AND dep-b are both tier=="core" -- but this
# run's arch list (below) only carries dep-a, mimicking a bad merge/typo'd
# rename/over-eager prune that silently drops dep-b from arches.json's
# gated set.
ARCHES_JSON_PATH_9="${WORKDIR}/arches-committed-9.json"
jq -n '[{name:"dep-a",tier:"core"},{name:"dep-b",tier:"core"}]' > "${ARCHES_JSON_PATH_9}"

RC=0
CALL_LOG="${CALL_LOG_9A}" ARCHES_JSON_PATH="${ARCHES_JSON_PATH_9}" \
    "${PUBLISH_FEED}" assemble "$(arches_json dep-a:core)" "${BUILT_APKS_9}" "${PAGES_ROOT_9A}" \
    >"${WORKDIR}/assemble-9a.log" 2>&1 || RC=$?

assert_eq "9a: a silently-missing committed core arch hard-fails assemble" "true" \
    "$([ "${RC}" -ne 0 ] && echo true || echo false)"
assert_contains "9a: names the missing core arch" "$(cat "${WORKDIR}/assemble-9a.log")" "dep-b"
assert_contains "9a: points at --allow-depublish as the deliberate override" \
    "$(cat "${WORKDIR}/assemble-9a.log")" "allow-depublish"
assert_eq "9a: fails BEFORE any signing work is dispatched (fail-fast pre-check)" "" \
    "$(cat "${CALL_LOG_9A}")"

echo

PAGES_ROOT_9B="${WORKDIR}/pages-root-9b"
CALL_LOG_9B="${WORKDIR}/call-log-9b"
: > "${CALL_LOG_9B}"

RC=0
CALL_LOG="${CALL_LOG_9B}" ARCHES_JSON_PATH="${ARCHES_JSON_PATH_9}" \
    "${PUBLISH_FEED}" assemble "$(arches_json dep-a:core)" "${BUILT_APKS_9}" "${PAGES_ROOT_9B}" \
    --allow-depublish dep-b \
    >"${WORKDIR}/assemble-9b.log" 2>&1 || RC=$?

assert_eq "9b: --allow-depublish dep-b lets the SAME scenario proceed (exit 0)" "0" "${RC}"
assert_contains "9b: logs a loud warning that dep-b was deliberately depublished" \
    "$(cat "${WORKDIR}/assemble-9b.log")" "dep-b"
assert_eq "9b: dep-a still published normally" "true" \
    "$([ -f "${PAGES_ROOT_9B}/apk/dep-a/packages.adb" ] && echo true || echo false)"

echo

# ===========================================================================
# 10. S7b: publish-time log() of the unverified tier (RFC §5.6/§Slices S7b)
# ===========================================================================
echo "=== 10. S7b: assemble logs which PUBLISHED arches are in the unverified tier ==="

# A richer committed-table fixture (real arches.json shape -- goarch/
# native_verify/reason, not just name+tier) so scripts/families.sh
# --unverified-arches can actually compute family grouping against it, per
# the RFC's "consult the committed table via ARCHES_JSON_PATH ... reuse
# D1's query" requirement. core-v1 is a boot-verified family (A64-shaped
# tuple, native_verify:true); the two ext-unverified-* arches belong to two
# DIFFERENT unverified families (riscv64 -> RV64-shaped, arm/goarm=6 ->
# A6HF-shaped) -- neither has any native_verify:true row anywhere in this
# table. (M8: field renamed from `verify` to `native_verify` -- see
# scripts/families.sh's header comment for why.)
ARCHES_JSON_PATH_10="${WORKDIR}/arches-committed-10.json"
jq -n '[
    {name:"core-v1", goarch:"arm64", goarm:"", gomips:"", gomips64:"", go386:"",
     endian:"little", float:"hard", reason:null, tier:"core", canary:false,
     rootfs_target:"armsr/armv8", rootfs_url:"https://example.invalid/armv8", rootfs_sha256:"deadbeef",
     container_arch:"aarch64", native_verify:true},
    {name:"ext-unverified-1", goarch:"riscv64", goarm:"", gomips:"", gomips64:"", go386:"",
     endian:"little", float:"hard", reason:null, tier:"extended", canary:false,
     rootfs_target:"", rootfs_url:"", rootfs_sha256:"",
     container_arch:"riscv64", native_verify:false},
    {name:"ext-unverified-2", goarch:"arm", goarm:"6", gomips:"", gomips64:"", go386:"",
     endian:"little", float:"hard", reason:null, tier:"extended", canary:false,
     rootfs_target:"", rootfs_url:"", rootfs_sha256:"",
     container_arch:"arm", native_verify:false}
]' > "${ARCHES_JSON_PATH_10}"

BUILT_APKS_10A="${WORKDIR}/built-apks-10a"
PAGES_ROOT_10A="${WORKDIR}/pages-root-10a"
CALL_LOG_10A="${WORKDIR}/call-log-10a"
: > "${CALL_LOG_10A}"
mk_built_apks "${BUILT_APKS_10A}" core-v1 ext-unverified-1 ext-unverified-2

RC=0
CALL_LOG="${CALL_LOG_10A}" ARCHES_JSON_PATH="${ARCHES_JSON_PATH_10}" TS_SIGN_CONCURRENCY=2 \
    "${PUBLISH_FEED}" assemble \
    "$(arches_json core-v1:core ext-unverified-1:extended ext-unverified-2:extended)" \
    "${BUILT_APKS_10A}" "${PAGES_ROOT_10A}" \
    >"${WORKDIR}/assemble-10a.log" 2>&1 || RC=$?

assert_eq "10a: mixed verified+unverified publish still exits 0 (log() is informational, never fails)" "0" "${RC}"
assert_contains "10a: names the unverified count (2)" "$(cat "${WORKDIR}/assemble-10a.log")" "2 published arch"
assert_contains "10a: names ext-unverified-1" "$(cat "${WORKDIR}/assemble-10a.log")" "ext-unverified-1"
assert_contains "10a: names ext-unverified-2" "$(cat "${WORKDIR}/assemble-10a.log")" "ext-unverified-2"
assert_contains "10a: states architectural-certainty / not CI-boot-verified" \
    "$(cat "${WORKDIR}/assemble-10a.log")" "NOT CI-boot-verified"
assert_contains "10a: cites the RFC S7b tier" "$(cat "${WORKDIR}/assemble-10a.log")" "S7b"
assert_not_contains "10a: does NOT list the verified arch (core-v1) among the unverified names" \
    "$(cat "${WORKDIR}/assemble-10a.log")" "unverified tier (RFC §5.6/S7b) -- shipped on architectural certainty only, NOT CI-boot-verified: core-v1"

echo

echo "=== 10b. S7b: a run publishing ONLY verified arches logs the clean line, no unverified names ==="

BUILT_APKS_10B="${WORKDIR}/built-apks-10b"
PAGES_ROOT_10B="${WORKDIR}/pages-root-10b"
CALL_LOG_10B="${WORKDIR}/call-log-10b"
: > "${CALL_LOG_10B}"
mk_built_apks "${BUILT_APKS_10B}" core-v1

RC=0
CALL_LOG="${CALL_LOG_10B}" ARCHES_JSON_PATH="${ARCHES_JSON_PATH_10}" TS_SIGN_CONCURRENCY=2 \
    "${PUBLISH_FEED}" assemble "$(arches_json core-v1:core)" "${BUILT_APKS_10B}" "${PAGES_ROOT_10B}" \
    >"${WORKDIR}/assemble-10b.log" 2>&1 || RC=$?

assert_eq "10b: verified-only publish exits 0" "0" "${RC}"
assert_contains "10b: logs the clean 'all published arches are CI-boot-verified' line" \
    "$(cat "${WORKDIR}/assemble-10b.log")" "CI-boot-verified"
assert_not_contains "10b: does NOT print the 'unverified tier' warning line at all" \
    "$(cat "${WORKDIR}/assemble-10b.log")" "unverified tier"
assert_not_contains "10b: does NOT name ext-unverified-1 (not published this run)" \
    "$(cat "${WORKDIR}/assemble-10b.log")" "ext-unverified-1"
assert_not_contains "10b: does NOT name ext-unverified-2 (not published this run)" \
    "$(cat "${WORKDIR}/assemble-10b.log")" "ext-unverified-2"

echo

# ===========================================================================
# 11. H1 regression (checkpoint laundering): a monotonicity rejection AFTER
#    a valid sign+H7-verify must NEVER be treated as checkpointed. Unlike
#    every test above (which stubs OUT publish-arch.sh entirely via
#    PUBLISH_ARCH_SH), this drives the REAL scripts/publish-arch.sh through
#    publish-feed.sh's own orchestration -- only publish-arch.sh's OWN
#    overridable collaborators (apk/adb-sign.py/feed-guard.sh/curl) are
#    stubbed, mirroring tests/apk/publish-arch.sh's own fixture style. This
#    is the only way to prove the fix genuinely closes the "sign succeeds,
#    H7 verify succeeds, THEN check-monotonic rejects -- does the rejected
#    packages.adb still get read as done by is_checkpointed()" gap the
#    finding describes, since publish-feed.sh's own checkpoint logic has no
#    visibility into a FAKE publish-arch.sh's internal write-then-reject
#    ordering.
# ===========================================================================
echo "=== 11. H1 regression: checkpoint laundering, driven through the REAL publish-arch.sh ==="

H1_DIR="${WORKDIR}/h1"
mkdir -p "${H1_DIR}/bin"

H1_PUBKEY="${H1_DIR}/apk-signing.pem"
printf -- '-----BEGIN PUBLIC KEY-----\nDUMMY\n-----END PUBLIC KEY-----\n' > "${H1_PUBKEY}"

# Real apk stub: only `mkndx --output <file> ...` matters.
H1_FAKE_APK="${H1_DIR}/bin/fake-apk.sh"
cat > "${H1_FAKE_APK}" <<'EOF'
#!/bin/sh
prev=""
out=""
for a in "$@"; do
    if [ "${prev}" = "--output" ]; then out="${a}"; fi
    prev="${a}"
done
[ -n "${out}" ] || { echo "fake-apk: no --output given: $*" >&2; exit 1; }
printf 'FAKE-UNSIGNED-INDEX' > "${out}"
EOF
chmod +x "${H1_FAKE_APK}"

# Real adb-sign.py stub: preimage/assemble/verify ALL succeed legitimately --
# this arch's sign step is entirely valid; only check-monotonic (below) will
# reject it. This is exactly the H1 scenario: a genuinely valid, H7-verified
# signature that a downstream gate still must be able to reject without a
# trace being left behind.
H1_FAKE_ADB_SIGN="${H1_DIR}/bin/fake-adb-sign.py"
cat > "${H1_FAKE_ADB_SIGN}" <<'EOF'
#!/usr/bin/env python3
import sys
cmd = sys.argv[1]
if cmd == "preimage":
    with open(sys.argv[4], "wb") as f:
        f.write(b"FAKE-PREIMAGE")
elif cmd == "assemble":
    unsigned, _pub, sig, out = sys.argv[2:6]
    with open(unsigned, "rb") as f:
        data = f.read()
    with open(sig, "rb") as f:
        sigdata = f.read()
    with open(out, "wb") as f:
        f.write(data + b"::SIGNED-OK::" + sigdata)
elif cmd == "verify":
    with open(sys.argv[2], "rb") as f:
        data = f.read()
    sys.exit(0 if b"SIGNED-OK" in data else 1)
else:
    sys.exit(2)
EOF
chmod +x "${H1_FAKE_ADB_SIGN}"

# Real curl stub: the sign POST always succeeds with a well-formed
# signature -- the retained-blob GET branch must never be reached here
# because plan-retention (below) must never be called at all.
H1_FAKE_CURL="${H1_DIR}/bin/curl"
cat > "${H1_FAKE_CURL}" <<'EOF'
#!/bin/sh
OUT_FILE=""
prev=""
for a in "$@"; do
    case "${prev}" in
        -o) OUT_FILE="${a}" ;;
    esac
    prev="${a}"
done
case " $* " in
    *" -X POST "*)
        BODY='{"signature":"'"$(printf 'FAKESIG' | base64 -w0)"'"}'
        if [ -n "${OUT_FILE}" ]; then printf '%s' "${BODY}" > "${OUT_FILE}"; else printf '%s' "${BODY}"; fi
        ;;
    *)
        echo "h1-fake-curl: unexpected invocation: $*" >&2
        exit 22
        ;;
esac
EOF
chmod +x "${H1_FAKE_CURL}"

# Real feed-guard.sh stub: check-monotonic REJECTS (a real downgrade) --
# the exact H1 scenario. plan-retention exits loudly/non-zero if ever
# reached, proving the short-circuit still holds through this real-script
# integration path too.
H1_FAKE_FEED_GUARD="${H1_DIR}/bin/fake-feed-guard.sh"
cat > "${H1_FAKE_FEED_GUARD}" <<'EOF'
#!/bin/sh
cmd="$1"; shift
case "${cmd}" in
    check-monotonic)
        echo "feed-guard.sh: refusing to publish: not strictly greater than live (H1 test-injected rejection)" >&2
        exit 1
        ;;
    plan-retention)
        echo "H1 test FAIL: plan-retention must never be reached after a monotonic rejection" >&2
        exit 9
        ;;
    *) exit 9 ;;
esac
EOF
chmod +x "${H1_FAKE_FEED_GUARD}"

BUILT_APKS_H1="${WORKDIR}/built-apks-h1"
mk_built_apks "${BUILT_APKS_H1}" h1-core
H1_SRC_APK=$(find "${BUILT_APKS_H1}" -type f -path "*/h1-core/*.apk")
H1_PUBLISHED_NAME=$(basename "${H1_SRC_APK}")

# --- 11a: cmd_worker itself must report this arch as failed, not checkpointed.
PAGES_ROOT_H1A="${WORKDIR}/pages-root-h1a"
RC=0
PUBLISH_ARCH_SH="${REPO_ROOT}/scripts/publish-arch.sh" \
    APK_BIN="${H1_FAKE_APK}" ADB_SIGN_PY="${H1_FAKE_ADB_SIGN}" FEED_GUARD="${H1_FAKE_FEED_GUARD}" \
    PUBKEY_PATH="${H1_PUBKEY}" PATH="${H1_DIR}/bin:${PATH}" SIGN_RETRY_DELAY=0 \
    "${PUBLISH_FEED}" --worker h1-core "${H1_SRC_APK}" "${H1_PUBLISHED_NAME}" "${PAGES_ROOT_H1A}" --tier core \
    >"${WORKDIR}/h1a-worker.log" 2>&1 || RC=$?

assert_eq "H1: --worker (driving the REAL publish-arch.sh) reports the monotonic rejection as a failure" "true" \
    "$([ "${RC}" -ne 0 ] && echo true || echo false)"
assert_eq "H1: no packages.adb is left at the final, checkpointable path despite the valid sign+H7-verify" "false" \
    "$([ -f "${PAGES_ROOT_H1A}/apk/h1-core/packages.adb" ] && echo true || echo false)"

# --- 11b: assemble's own final accounting (what actually decides what gets
# deployed) must likewise never treat this as done -- a core arch stuck this
# way must abort the WHOLE publish (RFC §5.4 all-or-nothing), never silently
# ship a partially-rejected tree.
PAGES_ROOT_H1B="${WORKDIR}/pages-root-h1b"
RC=0
PUBLISH_ARCH_SH="${REPO_ROOT}/scripts/publish-arch.sh" \
    APK_BIN="${H1_FAKE_APK}" ADB_SIGN_PY="${H1_FAKE_ADB_SIGN}" FEED_GUARD="${H1_FAKE_FEED_GUARD}" \
    PUBKEY_PATH="${H1_PUBKEY}" PATH="${H1_DIR}/bin:${PATH}" SIGN_RETRY_DELAY=0 \
    TS_SIGN_CONCURRENCY=1 TS_PUBLISH_MAX_ROUNDS=1 TS_PUBLISH_ROUND_DELAY=0 \
    "${PUBLISH_FEED}" assemble "$(arches_json h1-core:core)" "${BUILT_APKS_H1}" "${PAGES_ROOT_H1B}" \
    >"${WORKDIR}/h1b-assemble.log" 2>&1 || RC=$?

assert_eq "H1: assemble's final accounting fails the WHOLE publish (core arch never checkpoints, never silently deployed)" "true" \
    "$([ "${RC}" -ne 0 ] && echo true || echo false)"
assert_eq "H1: assemble never leaves a deployable packages.adb for the rejected core arch" "false" \
    "$([ -f "${PAGES_ROOT_H1B}/apk/h1-core/packages.adb" ] && echo true || echo false)"

echo

# ===========================================================================
# 12. H2 regression (diagnostics integrity): cmd_worker must propagate the
#    REAL exit code of a genuinely failing (non-bootstrap) publish-arch.sh,
#    not silently report success.
# ===========================================================================
echo "=== 12. H2 regression: cmd_worker propagates the real exit code on a non-bootstrap failure ==="

BUILT_APKS_H2="${WORKDIR}/built-apks-h2"
CALL_LOG_H2="${WORKDIR}/call-log-h2"
: > "${CALL_LOG_H2}"
mk_built_apks "${BUILT_APKS_H2}" h2-bad
H2_APK=$(find "${BUILT_APKS_H2}" -type f -path "*/h2-bad/*.apk")
H2_PUBLISHED_NAME=$(basename "${H2_APK}")

PAGES_ROOT_H2="${WORKDIR}/pages-root-h2"
RC=0
CALL_LOG="${CALL_LOG_H2}" ALWAYS_FAIL_ARCHES="h2-bad" \
    "${PUBLISH_FEED}" --worker h2-bad "${H2_APK}" "${H2_PUBLISHED_NAME}" "${PAGES_ROOT_H2}" --tier core \
    >"${WORKDIR}/h2-worker.log" 2>&1 || RC=$?

assert_eq "H2: --worker exits NON-ZERO for a genuinely failing (non-bootstrap) publish-arch.sh" "true" \
    "$([ "${RC}" -ne 0 ] && echo true || echo false)"
assert_contains "H2: the worker's own captured output still shows the underlying failure" \
    "$(cat "${WORKDIR}/h2-worker.log")" "forced PERMANENT failure"
assert_eq "H2: no packages.adb was produced for the failed arch" "false" \
    "$([ -f "${PAGES_ROOT_H2}/apk/h2-bad/packages.adb" ] && echo true || echo false)"

echo

harness_finish "tests/apk/publish-feed.sh"
