#!/bin/sh
# tests/apk/guard-hardening.sh
#
# Focused regression tests for two code-review findings that don't fit
# feed-publish.sh's existing check-monotonic/plan-retention/verify-tree
# sections:
#
#   M7  scripts/notify-alert.sh -- the webhook-POST curl-stderr capture must
#       use a unique mktemp path with trap cleanup, not a fixed, predictable
#       ${TMPDIR:-/tmp}/notify-alert.curl.err. Concurrent invocations on a
#       shared CI runner would otherwise race on that one path, and the file
#       was never cleaned up (leaks on every failing-webhook run).
#
#   L8  scripts/feed-guard.sh (check-monotonic) and scripts/detect-apk-drift.sh
#       both call `apk version -t A B` under `set -eu` with no exit-code
#       guard. `apk version -t` DOES exit non-zero for at least one
#       reachable input shape (verified directly against the pinned
#       apk-tools 3.0.2 binary: `apk version -t "" ""` -> empty stdout,
#       exit 1) -- an unguarded `CMP=$(apk version -t ...)` under `set -eu`
#       aborts the whole script right there, with NO diagnostic message and
#       an exit code that is outside either script's documented contract
#       (feed-guard.sh: 0 / 1 / die()'s 2; detect-apk-drift.sh: 0 / 1 / 2).
#       This test forces that failure via a fake `apk` shim placed ahead of
#       the real pinned binary on PATH -- rather than trying to construct a
#       "version string" apk's own `mkpkg` would even accept as invalid
#       (mkpkg validates version syntax at package-creation time, so a
#       genuinely malformed live/new index isn't constructible through the
#       normal toolchain). The shim proves the SHELL-LEVEL guard exists
#       independently of how such a value could arise in a real index.
#
# Usage: sh tests/apk/guard-hardening.sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
PKG_DIR="${REPO_ROOT}/tailscale-package"
FEED_GUARD="${REPO_ROOT}/scripts/feed-guard.sh"
NOTIFY_ALERT="${REPO_ROOT}/scripts/notify-alert.sh"
DETECT_DRIFT="${REPO_ROOT}/scripts/detect-apk-drift.sh"

# shellcheck source=tests/apk/lib.sh
. "${SCRIPT_DIR}/lib.sh"

require_cmd docker
require_cmd curl
require_cmd jq

WORKDIR=$(mktemp -d)
cleanup() { rm -rf "${WORKDIR}"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# M7: notify-alert.sh curl-stderr tempfile hygiene
# ---------------------------------------------------------------------------
echo "=== M7: notify-alert.sh curl-stderr tempfile (mktemp + trap, no leak) ==="

PRIVATE_TMPDIR="${WORKDIR}/notify-tmp"
mkdir -p "${PRIVATE_TMPDIR}"

# Unreachable webhook target (nothing listening on 127.0.0.1:1) -> curl
# fails fast and predictably, exercising the failure-path branch that writes
# to the curl-stderr tempfile.
if TMPDIR="${PRIVATE_TMPDIR}" ALERT_WEBHOOK_URL="http://127.0.0.1:1/webhook" \
        sh "${NOTIFY_ALERT}" "test alert" >"${WORKDIR}/notify-out.log" 2>&1
then
    RC=0
else
    RC=$?
fi
assert_eq "notify-alert.sh always exits 0 (best-effort notifier)" "0" "${RC}"

assert_eq "no leftover tempfile in TMPDIR after a single run (mktemp + trap cleanup, not a leaked fixed path)" "" \
    "$(ls "${PRIVATE_TMPDIR}" 2>/dev/null)"

# Concurrency proof: two invocations sharing the same TMPDIR and both hitting
# the failure branch at (roughly) the same time must not race on a shared
# fixed path, and both must still leave TMPDIR clean afterward.
TMPDIR="${PRIVATE_TMPDIR}" ALERT_WEBHOOK_URL="http://127.0.0.1:1/webhook" \
    sh "${NOTIFY_ALERT}" "concurrent alert A" >"${WORKDIR}/conc-a.log" 2>&1 &
PID_A=$!
TMPDIR="${PRIVATE_TMPDIR}" ALERT_WEBHOOK_URL="http://127.0.0.1:1/webhook" \
    sh "${NOTIFY_ALERT}" "concurrent alert B" >"${WORKDIR}/conc-b.log" 2>&1 &
PID_B=$!
wait "${PID_A}"; RC_A=$?
wait "${PID_B}"; RC_B=$?

assert_eq "concurrent invocation A exits 0" "0" "${RC_A}"
assert_eq "concurrent invocation B exits 0" "0" "${RC_B}"
assert_eq "TMPDIR still clean after two concurrent invocations (unique mktemp names, no shared-path race, no leak)" "" \
    "$(ls "${PRIVATE_TMPDIR}" 2>/dev/null)"

echo

# ---------------------------------------------------------------------------
# apk-tools binary + fake-apk shim (for the L8 tests below)
# ---------------------------------------------------------------------------
echo "=== extracting pinned apk-tools binary ==="
REAL_BIN_DIR="${WORKDIR}/real-bin"
extract_apk_tools_binary "${REAL_BIN_DIR}" "${PKG_DIR}"

# Confirm the assumption this test relies on: `apk version -t` really can
# exit non-zero on some input, so the guard being tested is not vacuous.
if PATH="${REAL_BIN_DIR}:${PATH}" apk version -t "" "" >/dev/null 2>&1; then
    echo "FAIL: precondition broken -- 'apk version -t \"\" \"\"' unexpectedly succeeded against the pinned apk-tools binary; this test's fake-apk shim technique needs revisiting" >&2
    exit 1
fi

SHIM_DIR="${WORKDIR}/shim-bin"
mkdir -p "${SHIM_DIR}"
cat > "${SHIM_DIR}/apk" <<SHIMEOF
#!/bin/sh
# Forwards every subcommand to the real pinned apk EXCEPT "version -t",
# which always fails (no output, exit 1) to simulate an unexpected/
# unhandled apk-tools failure mode.
if [ "\${1:-}" = "version" ] && [ "\${2:-}" = "-t" ]; then
    exit 1
fi
exec "${REAL_BIN_DIR}/apk" "\$@"
SHIMEOF
chmod +x "${SHIM_DIR}/apk"

mk_index() {
    _ver="$1"; _out="$2"
    mkdir -p "${WORKDIR}/pkgroot-empty"
    PATH="${REAL_BIN_DIR}:${PATH}" apk mkpkg --allow-untrusted --info "name:tailscale" --info "version:${_ver}" \
        --info "arch:aarch64_cortex-a53" --files "${WORKDIR}/pkgroot-empty" \
        --output "${WORKDIR}/gh-idx-${_ver}.apk" >/dev/null
    PATH="${REAL_BIN_DIR}:${PATH}" apk mkndx --allow-untrusted --compression none --output "${_out}" "${WORKDIR}/gh-idx-${_ver}.apk" >/dev/null
}

mk_index "1.98.8-r1" "${WORKDIR}/gh-live.adb"
mk_index "1.99.0-r1" "${WORKDIR}/gh-new.adb"

echo

# ---------------------------------------------------------------------------
# L8: scripts/feed-guard.sh check-monotonic -- guarded apk version -t
# ---------------------------------------------------------------------------
echo "=== L8: feed-guard.sh check-monotonic guards 'apk version -t' ==="

if PATH="${SHIM_DIR}:${REAL_BIN_DIR}:${PATH}" sh "${FEED_GUARD}" check-monotonic \
        "${WORKDIR}/gh-new.adb" "${WORKDIR}/gh-live.adb" \
        >"${WORKDIR}/fg-guard.log" 2>&1
then
    RC=0
else
    RC=$?
fi

assert_eq "unexpected 'apk version -t' failure is a hard error (exit 2), not an uncontrolled abort" "2" "${RC}"
assert_contains "hard-error path prints a diagnostic (not a silent crash)" \
    "$(cat "${WORKDIR}/fg-guard.log")" "feed-guard.sh:"

echo

# ---------------------------------------------------------------------------
# L8: scripts/detect-apk-drift.sh -- guarded apk version -t
# ---------------------------------------------------------------------------
echo "=== L8: detect-apk-drift.sh guards 'apk version -t' ==="

if PATH="${SHIM_DIR}:${REAL_BIN_DIR}:${PATH}" sh "${DETECT_DRIFT}" \
        "v1.99.0" "${WORKDIR}/gh-live.adb" \
        >"${WORKDIR}/dd-guard.log" 2>&1
then
    RC=0
else
    RC=$?
fi

assert_eq "unexpected 'apk version -t' failure is exit 2 (documented HARD ERROR), not an uncontrolled abort" "2" "${RC}"
assert_contains "hard-error path prints a diagnostic (not a silent crash)" \
    "$(cat "${WORKDIR}/dd-guard.log")" "ERROR:"

harness_finish "tests/apk/guard-hardening.sh"
