#!/bin/sh
# tests/apk/failure-isolation.sh
#
# Slice C5 test (RFC docs/rfc-apk-builds.md §4.6, §6 slice C5): the
# resilience slice from the outage post-mortem. Five things under test:
#
#   1. Isolation (the load-bearing assertion) -- parses the
#      build-tailscale.yaml DAG (python+yaml) and asserts the `release`
#      job's TRANSITIVE `needs` closure contains no apk job. This is a
#      structural proof, not a live simulation: GitHub Actions schedules
#      jobs strictly off `needs:`/`if:`, so if `release`'s closure never
#      references an apk job, NO possible apk-job outcome (success,
#      failure, skip) can affect whether `release` runs or what it does --
#      "prove that with apk-sign-verify marked failed, release's condition
#      is unaffected" reduces exactly to this closure containing no apk job.
#      Also asserts the apk best-effort jobs (apk-sign-verify, publish-feed,
#      release-apk-assets) carry `if: ... !cancelled() ...`.
#   2. Alerting -- asserts an `if: failure()`-guarded step exists on each
#      apk-path job that can fail after a signing/publish attempt.
#   3. Republish -- structural: workflow_dispatch has `republish`/
#      `republish_tag` inputs; a `republish-feed` job exists, is gated on
#      `republish == 'true'`, and does NOT need a full rebuild (build-ipk/
#      build-apk/release are absent from its needs).
#   4. Cron self-heal -- unit tests scripts/detect-apk-drift.sh directly
#      against local index fixtures (mirrors feed-guard.sh's own local-file
#      test affordance): release-newer-than-feed -> drift; matching -> in
#      sync; feed entirely absent -> drift; feed unreachable -> hard error
#      (never silently treated as either).
#   5. Synthetic probe -- unit tests scripts/probe-feed.sh against a REAL
#      locally-signed, locally-served feed (same recipe as
#      tests/apk/feed-publish.sh's verify-tree section): passes when
#      everything is valid; fails distinctly on a tampered signature, a
#      version mismatch, and (via a real self-signed-cert HTTPS server) an
#      invalid TLS certificate -- RED proof that the "TLS/cert validity"
#      check is a real curl-level verification, not a placeholder.
#
# Also asserts both workflow YAML files are well-formed.
#
# Uses the shared tests/apk/lib.sh harness (established slice A2).
#
# Usage: sh tests/apk/failure-isolation.sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
BUILD_WORKFLOW="${REPO_ROOT}/.github/workflows/build-tailscale.yaml"
CHECK_WORKFLOW="${REPO_ROOT}/.github/workflows/check-releases.yaml"
PKG_DIR="${REPO_ROOT}/tailscale-package"
DETECT_DRIFT="${REPO_ROOT}/scripts/detect-apk-drift.sh"
PROBE_FEED="${REPO_ROOT}/scripts/probe-feed.sh"
NOTIFY_ALERT="${REPO_ROOT}/scripts/notify-alert.sh"
ADB_SIGN_PY="${REPO_ROOT}/scripts/adb-sign.py"

# shellcheck source=tests/apk/lib.sh
. "${SCRIPT_DIR}/lib.sh"

require_cmd jq
require_cmd python3
require_cmd docker
require_cmd openssl
require_cmd curl

for f in "${BUILD_WORKFLOW}" "${CHECK_WORKFLOW}" "${DETECT_DRIFT}" "${PROBE_FEED}" "${NOTIFY_ALERT}" "${ADB_SIGN_PY}"; do
    [ -f "${f}" ] || { echo "FAIL: ${f} not found" >&2; exit 1; }
done

WORKDIR=$(mktemp -d)
SRV_PIDS=""
cleanup() {
    for p in ${SRV_PIDS}; do kill "${p}" >/dev/null 2>&1 || true; done
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT

# ===========================================================================
# 1. Isolation: the DAG structural proof
# ===========================================================================
echo "=== 1. isolation: release job's transitive needs contain no apk job ==="

STRUCT_JSON=$(python3 - "${BUILD_WORKFLOW}" <<'PYEOF'
import sys, json, yaml

with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)

result = {"yaml_ok": True}
jobs = doc.get("jobs", {}) or {}
# PyYAML (YAML 1.1) parses the bare `on:` key as the boolean True, not the
# string "on" -- a well-known GitHub-Actions-YAML-via-PyYAML gotcha. Look it
# up both ways so this keeps working regardless of PyYAML version/config.
on_block = doc.get("on", doc.get(True, {})) or {}
inputs = ((on_block.get("workflow_dispatch", {}) or {}).get("inputs", {}) or {})

APK_JOBS = {"build-apk", "apk-sign-verify", "publish-feed", "release-apk-assets", "republish-feed"}
result["apk_jobs_present"] = sorted(j for j in APK_JOBS if j in jobs)


def needs_list(job):
    n = job.get("needs", [])
    if isinstance(n, str):
        n = [n]
    return list(n)


def transitive_needs(start):
    seen = set()
    stack = [start]
    while stack:
        name = stack.pop()
        job = jobs.get(name, {}) or {}
        for n in needs_list(job):
            if n not in seen:
                seen.add(n)
                stack.append(n)
    return seen

release_closure = transitive_needs("release")
result["release_transitive_needs"] = sorted(release_closure)
result["release_closure_contains_apk_job"] = sorted(release_closure & APK_JOBS)

# release-apk-assets DOES (deliberately, one-way) need `release` -- confirm
# the reverse is not also true anywhere (no cycle, no apk job upstream of
# release through any other path either).
all_apk_adjacent = set()
for name in APK_JOBS:
    all_apk_adjacent |= transitive_needs(name)
result["apk_jobs_transitively_need_release"] = "release" in all_apk_adjacent  # only release-apk-assets should, checked separately
result["release_apk_assets_needs_release"] = "release" in needs_list(jobs.get("release-apk-assets", {}) or {})

# --- best-effort jobs carry if: ... !cancelled() ... ----------------------
def if_expr(job):
    return str(job.get("if", ""))

BEST_EFFORT = ["apk-sign-verify", "publish-feed", "release-apk-assets"]
result["best_effort_has_cancelled_guard"] = {
    name: ("!cancelled()" in if_expr(jobs.get(name, {}) or {})) for name in BEST_EFFORT
}

# republish-feed job shape (checked fully in section 3, but grab needs here)
result["republish_feed_needs"] = sorted(needs_list(jobs.get("republish-feed", {}) or {}))
result["republish_feed_if"] = if_expr(jobs.get("republish-feed", {}) or {})

result["workflow_dispatch_inputs"] = sorted(inputs.keys())

# --- alerting: which apk-path jobs carry an if: failure() step -----------
def failure_steps(job):
    out = []
    for step in job.get("steps", []) or []:
        if "failure()" in str(step.get("if", "")):
            out.append(step.get("name", "<unnamed>"))
    return out

result["failure_alert_steps"] = {
    name: failure_steps(jobs.get(name, {}) or {}) for name in sorted(APK_JOBS)
}

# ALERT_WEBHOOK_URL is read from a secret/env, never hardcoded as a literal
# URL in the workflow text.
full_text = json.dumps(doc)
result["alert_uses_secret_not_hardcoded"] = (
    "secrets.ALERT_WEBHOOK_URL" in full_text
    and "ntfy.sh/" not in full_text
    and "hooks.slack.com" not in full_text
)

print(json.dumps(result))
PYEOF
)

assert_eq "build-tailscale.yaml YAML parses" "true" "$(echo "${STRUCT_JSON}" | jq -r '.yaml_ok')"

APK_JOBS_PRESENT=$(echo "${STRUCT_JSON}" | jq -c '.apk_jobs_present')
assert_eq "all expected apk-path jobs exist" '["apk-sign-verify","build-apk","publish-feed","release-apk-assets","republish-feed"]' "${APK_JOBS_PRESENT}"

RELEASE_CLOSURE_APK=$(echo "${STRUCT_JSON}" | jq -c '.release_closure_contains_apk_job')
assert_eq "release job's transitive needs contain NO apk job (load-bearing isolation assertion)" '[]' "${RELEASE_CLOSURE_APK}"

RELEASE_CLOSURE=$(echo "${STRUCT_JSON}" | jq -c '.release_transitive_needs')
echo "  (release's full transitive needs closure: ${RELEASE_CLOSURE})"

assert_eq "release-apk-assets needs release (one-way, deliberate -- C4)" "true" \
    "$(echo "${STRUCT_JSON}" | jq -r '.release_apk_assets_needs_release')"

echo
echo "--- simulated failure: with apk-sign-verify marked failed, release's condition is unaffected ---"
echo "  Proof: release's needs/if never reference apk-sign-verify (confirmed above via the"
echo "  transitive closure) -- GitHub Actions schedules jobs purely off needs:/if:, so no"
echo "  runtime outcome of apk-sign-verify (success, failure, or skip) can change whether"
echo "  release runs or what it does. This IS the simulation: the DAG shape make the failure"
echo "  mode structurally unreachable, not merely untested."
log_info "OK: release's scheduling is structurally independent of apk-sign-verify's result"

echo
for j in apk-sign-verify publish-feed release-apk-assets; do
    HAS_GUARD=$(echo "${STRUCT_JSON}" | jq -r --arg j "$j" '.best_effort_has_cancelled_guard[$j]')
    assert_eq "${j} carries an if: ...!cancelled()... guard (apk best-effort, §4.6)" "true" "${HAS_GUARD}"
done

echo

# ===========================================================================
# 2. Alerting
# ===========================================================================
echo "=== 2. alerting: if: failure()-guarded step(s) exist on the apk path ==="

for j in apk-sign-verify publish-feed release-apk-assets republish-feed build-apk; do
    COUNT=$(echo "${STRUCT_JSON}" | jq -r --arg j "$j" '.failure_alert_steps[$j] | length')
    assert_eq "${j} has an if: failure()-guarded alert step" "true" "$([ "${COUNT}" -ge 1 ] && echo true || echo false)"
done

assert_eq "alert target is read from a secret (ALERT_WEBHOOK_URL), not hardcoded" "true" \
    "$(echo "${STRUCT_JSON}" | jq -r '.alert_uses_secret_not_hardcoded')"

echo

# ===========================================================================
# 3. Republish workflow_dispatch structural shape
# ===========================================================================
echo "=== 3. republish workflow_dispatch input + narrow publish-only path ==="

INPUTS=$(echo "${STRUCT_JSON}" | jq -c '.workflow_dispatch_inputs')
assert_contains "workflow_dispatch has a 'republish' input" "${INPUTS}" '"republish"'
assert_contains "workflow_dispatch has a 'republish_tag' input" "${INPUTS}" '"republish_tag"'

REPUBLISH_IF=$(echo "${STRUCT_JSON}" | jq -r '.republish_feed_if')
assert_contains "republish-feed job is gated on republish == 'true'" "${REPUBLISH_IF}" "inputs.republish == 'true'"

REPUBLISH_NEEDS=$(echo "${STRUCT_JSON}" | jq -c '.republish_feed_needs')
for forbidden in build-ipk build-apk release select-matrix; do
    CONTAINS=$(echo "${REPUBLISH_NEEDS}" | jq --arg f "${forbidden}" 'index($f) != null')
    assert_eq "republish-feed does NOT need '${forbidden}' (no full rebuild, §4.6)" "false" "${CONTAINS}"
done

echo

# ===========================================================================
# 3b. S5b: republish-feed rollback allowlist -- "rollback only ever touches
# core" (RFC §5.8 rollback note + S5b deliverable 4).
# ===========================================================================
#
# The RFC's §5.8 rollback note asks for an "arch-allowlist input" so
# republish-feed can't silently drop a live core arch. Investigating
# republish-feed's ACTUAL shape (both loops below): it already hardcodes
# `select(.tier == "core")` straight off arches.json for BOTH the
# assemble+sign+guard+retain loop and the post-publish verify loop -- it
# unconditionally republishes the WHOLE committed core set every run, never
# a caller-supplied subset. That means there is no code path by which a
# republish can drop ONE core arch while keeping others (the exact
# "allowlist" hazard the RFC note is guarding against) -- the depublish risk
# an allowlist-style input would create (a partial/stale allowlist silently
# omitting an arch) cannot arise because no allowlist input exists to go
# stale. Per this slice's own instructions: "if the existing filter already
# fully satisfies 'rollback only touches core,' assert that with a test and
# note it -- don't manufacture new mechanism." Asserted here rather than
# adding a new (redundant, and itself a new drift-risk) allowlist mechanism.
echo "=== 3b. S5b: republish-feed's rollback is already core-only in BOTH loops (no allowlist mechanism needed) ==="

REPUBLISH_STRUCT_JSON=$(python3 - "${BUILD_WORKFLOW}" <<'PYEOF'
import sys, json, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)
jobs = doc.get("jobs", {}) or {}
rf_job = jobs.get("republish-feed", {}) or {}

def run_text(step_name_substr):
    for step in rf_job.get("steps", []) or []:
        if step_name_substr in str(step.get("name", "")):
            return str(step.get("run", ""))
    return ""

result = {
    "assemble_step_run": run_text("Assemble"),
    "verify_step_run": run_text("verify"),
}
print(json.dumps(result))
PYEOF
)

ASSEMBLE_RUN=$(echo "${REPUBLISH_STRUCT_JSON}" | jq -r '.assemble_step_run')
VERIFY_RUN=$(echo "${REPUBLISH_STRUCT_JSON}" | jq -r '.verify_step_run')

assert_contains "republish-feed's assemble+sign+guard+retain loop filters arches.json to tier==\"core\" only" \
    "${ASSEMBLE_RUN}" 'select(.tier == "core")'
assert_contains "republish-feed's post-publish verify loop ALSO filters to tier==\"core\" only" \
    "${VERIFY_RUN}" 'select(.tier == "core")'

echo

# ===========================================================================
# YAML well-formedness (both workflows)
# ===========================================================================
echo "=== YAML well-formed (both workflows) ==="
CHECK_YAML_OK=$(python3 -c "
import yaml
with open('${CHECK_WORKFLOW}') as f:
    yaml.safe_load(f)
print('true')
" 2>/dev/null || echo "false")
assert_eq "check-releases.yaml YAML parses" "true" "${CHECK_YAML_OK}"

CHECK_STRUCT=$(python3 - "${CHECK_WORKFLOW}" <<'PYEOF'
import sys, json, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)
steps = doc["jobs"]["check"]["steps"]
names = [s.get("name", "") for s in steps]
text = json.dumps(doc)
result = {
    "has_drift_step": any("drift" in n.lower() for n in names),
    "has_probe_step": any("probe" in n.lower() for n in names),
    "has_republish_dispatch": "republish=true" in text or "'republish=true'" in text,
    "calls_detect_drift_script": "detect-apk-drift.sh" in text,
    "calls_probe_script": "probe-feed.sh" in text,
    "calls_notify_alert": "notify-alert.sh" in text,
    "keepalive_step_present": any("keepalive" in n.lower() for n in names),
    # RFC docs/rfc-apk-arch-coverage.md §5.8 slice S1c: the drift/probe
    # arch selection used to be `.[0].name` -- order-fragile now that
    # arches.json is a 35-row table (S1b) with a content-derived, not
    # positional, row order. It must be canary-keyed instead.
    "arch_selection_canary_keyed": text.count("select(.canary == true)") >= 2,
    "arch_selection_no_positional_index": ".[0].name" not in text,
}
print(json.dumps(result))
PYEOF
)
assert_eq "check-releases.yaml has a drift-detection step" "true" "$(echo "${CHECK_STRUCT}" | jq -r '.has_drift_step')"
assert_eq "check-releases.yaml has a synthetic probe step" "true" "$(echo "${CHECK_STRUCT}" | jq -r '.has_probe_step')"
assert_eq "check-releases.yaml auto-fires a republish=true dispatch" "true" "$(echo "${CHECK_STRUCT}" | jq -r '.has_republish_dispatch')"
assert_eq "check-releases.yaml calls scripts/detect-apk-drift.sh" "true" "$(echo "${CHECK_STRUCT}" | jq -r '.calls_detect_drift_script')"
assert_eq "check-releases.yaml calls scripts/probe-feed.sh" "true" "$(echo "${CHECK_STRUCT}" | jq -r '.calls_probe_script')"
assert_eq "check-releases.yaml reuses scripts/notify-alert.sh (same alert channel)" "true" "$(echo "${CHECK_STRUCT}" | jq -r '.calls_notify_alert')"
assert_eq "check-releases.yaml's existing keepalive step is still present (extend, don't replace)" "true" "$(echo "${CHECK_STRUCT}" | jq -r '.keepalive_step_present')"
assert_eq "check-releases.yaml's drift+probe arch selection is canary-keyed (both steps)" "true" \
    "$(echo "${CHECK_STRUCT}" | jq -r '.arch_selection_canary_keyed')"
assert_eq "check-releases.yaml no longer uses the order-fragile .[0].name selector" "true" \
    "$(echo "${CHECK_STRUCT}" | jq -r '.arch_selection_no_positional_index')"

echo

# ---------------------------------------------------------------------------
# canary-keyed selection is order-independent (S1c): a row-order shuffle of
# arches.json must not change which arch check-releases.yaml's probe/drift
# steps select. This is the docker-free unit check for the fix -- proves the
# `select(.canary == true)` jq expression itself (not just its presence in
# the YAML text) is insensitive to row order, unlike the `.[0].name` it
# replaced.
# ---------------------------------------------------------------------------
echo "=== check-releases probe/drift arch selection is order-independent (canary-keyed) ==="

ARCHES_JSON="${REPO_ROOT}/arches.json"
SHUFFLED_ARCHES="${WORKDIR}/arches-shuffled.json"
jq '[.[]] | sort_by(.name) | reverse' "${ARCHES_JSON}" > "${SHUFFLED_ARCHES}"

ORIG_SELECTED=$(jq -r '.[] | select(.canary == true) | .name' "${ARCHES_JSON}")
SHUFFLED_SELECTED=$(jq -r '.[] | select(.canary == true) | .name' "${SHUFFLED_ARCHES}")

assert_eq "canary selection is exactly mips_24kc on the committed (unshuffled) table" "mips_24kc" "${ORIG_SELECTED}"
assert_eq "canary selection is UNCHANGED after reversing row order (order-independence)" "${ORIG_SELECTED}" "${SHUFFLED_SELECTED}"

# Contrast with the old, deleted `.[0].name` selector: on the same shuffled
# table it would select a different arch entirely -- proof this isn't
# vacuously true because the table happens to still start with mips_24kc.
OLD_SELECTOR_ON_SHUFFLED=$(jq -r '.[0].name' "${SHUFFLED_ARCHES}")
assert_eq "regression check: the OLD .[0].name selector WOULD have changed under the same shuffle" "true" \
    "$([ "${OLD_SELECTOR_ON_SHUFFLED}" != "mips_24kc" ] && echo true || echo false)"

echo

# ===========================================================================
# apk-tools binary, needed for detect-apk-drift.sh / probe-feed.sh (adbdump,
# mkndx, version -t)
# ===========================================================================
echo "=== extracting pinned apk-tools binary ==="
BIN_DIR="${WORKDIR}/bin"
extract_apk_tools_binary "${BIN_DIR}" "${PKG_DIR}"
PATH="${BIN_DIR}:${PATH}"
export PATH
apk --version >&2

mk_index() {
    # mk_index <version> <out_adb> -- a tiny single-package UNSIGNED index at
    # the given tailscale version (mirrors tests/apk/feed-publish.sh's own
    # helper -- version-comparison logic doesn't care about signing).
    _ver="$1"; _out="$2"
    mkdir -p "${WORKDIR}/pkgroot-empty"
    apk mkpkg --allow-untrusted --info "name:tailscale" --info "version:${_ver}" \
        --info "arch:aarch64_cortex-a53" --files "${WORKDIR}/pkgroot-empty" \
        --output "${WORKDIR}/idx-${_ver}.apk" >/dev/null
    apk mkndx --allow-untrusted --compression none --output "${_out}" "${WORKDIR}/idx-${_ver}.apk" >/dev/null
}

echo

# ===========================================================================
# 4. Cron self-heal: scripts/detect-apk-drift.sh unit tests
# ===========================================================================
echo "=== 4. cron self-heal (scripts/detect-apk-drift.sh) ==="

mk_index "1.98.8-r1" "${WORKDIR}/feed-current.adb"
mk_index "1.98.0-r1" "${WORKDIR}/feed-stale.adb"

drift_rc() {
    _tag="$1"; _src="$2"
    if sh "${DETECT_DRIFT}" "${_tag}" "${_src}" >"${WORKDIR}/drift-out.log" 2>&1; then
        echo 0
    else
        echo "$?"
    fi
}

RC=$(drift_rc "v1.98.8" "${WORKDIR}/feed-current.adb")
assert_eq "release == feed version: in sync (exit 0)" "0" "${RC}"

RC=$(drift_rc "v1.98.8" "${WORKDIR}/feed-stale.adb")
assert_eq "release NEWER than feed version: drift, self-heal should fire (exit 1)" "1" "${RC}"
assert_contains "drift output names the cause" "$(cat "${WORKDIR}/drift-out.log")" "DRIFT"

RC=$(drift_rc "v1.98.8" "${WORKDIR}/does-not-exist.adb")
assert_eq "feed entirely absent (never published): drift, self-heal should fire (exit 1)" "1" "${RC}"
assert_contains "absent-feed drift output explains why" "$(cat "${WORKDIR}/drift-out.log")" "never published"

RC=$(drift_rc "v1.98.8" "http://127.0.0.1:1/packages.adb")
assert_eq "feed unreachable (hard network error): NOT auto-healed, hard error (exit 2)" "2" "${RC}"
assert_contains "hard-error output is distinguishable from a drift/in-sync result" \
    "$(cat "${WORKDIR}/drift-out.log")" "ERROR"

echo

# ===========================================================================
# 5. Synthetic probe: scripts/probe-feed.sh unit tests
# ===========================================================================
echo "=== 5. synthetic feed/cert probe (scripts/probe-feed.sh) ==="

TREE="${WORKDIR}/tree"
mkdir -p "${TREE}/apk/aarch64_cortex-a53" "${TREE}/apk/keys"

apk mkpkg --allow-untrusted --info "name:tailscale" --info "version:1.98.8-r1" \
    --info "arch:aarch64_cortex-a53" --files "${WORKDIR}/pkgroot-empty" \
    --output "${TREE}/apk/aarch64_cortex-a53/tailscale-1.98.8-r1.apk" >/dev/null
apk mkndx --allow-untrusted --compression none --output "${WORKDIR}/unsigned.adb" \
    "${TREE}/apk/aarch64_cortex-a53"/*.apk >/dev/null

openssl ecparam -genkey -name prime256v1 -noout -out "${WORKDIR}/probe-key.pem" 2>/dev/null
openssl ec -in "${WORKDIR}/probe-key.pem" -pubout -out "${TREE}/apk/keys/tailscale.pem" 2>/dev/null
python3 "${ADB_SIGN_PY}" preimage "${WORKDIR}/unsigned.adb" "${TREE}/apk/keys/tailscale.pem" "${WORKDIR}/probe-preimage.bin" 2>/dev/null
openssl dgst -sha512 -sign "${WORKDIR}/probe-key.pem" -out "${WORKDIR}/probe-sig.der" "${WORKDIR}/probe-preimage.bin"
python3 "${ADB_SIGN_PY}" assemble "${WORKDIR}/unsigned.adb" "${TREE}/apk/keys/tailscale.pem" "${WORKDIR}/probe-sig.der" \
    "${TREE}/apk/aarch64_cortex-a53/packages.adb" 2>/dev/null

HTTP_PORT=18493
( cd "${TREE}" && exec python3 -m http.server "${HTTP_PORT}" >"${WORKDIR}/httpd.log" 2>&1 ) &
SRV_PIDS="${SRV_PIDS} $!"
_i=0
while [ "${_i}" -lt 30 ]; do
    curl -fsS -o /dev/null "http://127.0.0.1:${HTTP_PORT}/apk/aarch64_cortex-a53/packages.adb" 2>/dev/null && break
    _i=$((_i + 1)); sleep 0.2
done

BASE="http://127.0.0.1:${HTTP_PORT}/apk/aarch64_cortex-a53"
PUBKEY_URL="http://127.0.0.1:${HTTP_PORT}/apk/keys/tailscale.pem"

if sh "${PROBE_FEED}" "${BASE}" "${PUBKEY_URL}" "v1.98.8" >"${WORKDIR}/probe-ok.log" 2>&1; then
    log_info "OK: probe-feed.sh passes against a correctly served, correctly signed, current feed"
    assert_contains "probe confirms signature validity" "$(cat "${WORKDIR}/probe-ok.log")" "signature verifies"
    assert_contains "probe confirms version currency" "$(cat "${WORKDIR}/probe-ok.log")" "matches or is ahead"
else
    log_fail "probe-feed.sh unexpectedly FAILED against a valid feed: $(cat "${WORKDIR}/probe-ok.log")"
fi

# RED proof: version mismatch (release tag ahead of what the feed serves) ->
# the probe must fail on the version-currency check specifically.
if sh "${PROBE_FEED}" "${BASE}" "${PUBKEY_URL}" "v1.99.0" >"${WORKDIR}/probe-stale.log" 2>&1; then
    log_fail "probe-feed.sh unexpectedly PASSED against a stale feed version -- version-currency check is not real"
else
    log_info "OK: probe-feed.sh correctly REJECTS a feed whose version doesn't match the latest release"
    assert_contains "stale-version failure names the cause" "$(cat "${WORKDIR}/probe-stale.log")" "does NOT match"
fi

# RED proof: a tampered signature (flip a byte inside the served index's
# ADB_BLOCK_ADB payload -- invalidates the signed digest regardless of where
# in the payload it lands) -> the probe's signature check must fail.
cp "${TREE}/apk/aarch64_cortex-a53/packages.adb" "${WORKDIR}/tampered.adb"
python3 - "${WORKDIR}/tampered.adb" <<'PYEOF'
import sys
path = sys.argv[1]
data = bytearray(open(path, "rb").read())
# Byte 20 is safely inside the ADB_BLOCK_ADB payload (starts at offset 12)
# for this minimal single-package index -- flipping it changes the payload
# hash the signature was computed over, without touching the file's magic/
# schema/block-header framing.
data[20] ^= 0x01
open(path, "wb").write(data)
PYEOF
cp "${TREE}/apk/aarch64_cortex-a53/packages.adb" "${WORKDIR}/orig-packages.adb.bak"
cp "${WORKDIR}/tampered.adb" "${TREE}/apk/aarch64_cortex-a53/packages.adb"

if sh "${PROBE_FEED}" "${BASE}" "${PUBKEY_URL}" "v1.98.8" >"${WORKDIR}/probe-tampered.log" 2>&1; then
    log_fail "probe-feed.sh unexpectedly PASSED against a tampered served index -- signature check is not real"
else
    log_info "OK: probe-feed.sh correctly REJECTS a tampered served index (signature check is real)"
    assert_contains "tampered-signature failure names the cause" "$(cat "${WORKDIR}/probe-tampered.log")" "signature"
fi

# restore the good index for the http server (not strictly needed again, but
# tidy if this script grows more cases later)
cp "${WORKDIR}/orig-packages.adb.bak" "${TREE}/apk/aarch64_cortex-a53/packages.adb"

# RED proof: TLS/cert validity is a REAL check, not a placeholder -- serve
# the same tree over HTTPS with a genuine self-signed cert (no CA anyone
# trusts) and confirm probe-feed.sh's plain `curl -fsS` (no -k) rejects it,
# distinctly labeled as a certificate problem (not lumped in with a generic
# network failure).
CERT_TEST_OK=1
if command -v openssl >/dev/null 2>&1 && openssl s_server -help >/dev/null 2>&1; then
    openssl req -x509 -newkey rsa:2048 -keyout "${WORKDIR}/tls-key.pem" -out "${WORKDIR}/tls-cert.pem" \
        -days 1 -nodes -subj "/CN=localhost" 2>/dev/null
    TLS_PORT=18494
    ( cd "${TREE}" && exec openssl s_server -accept "${TLS_PORT}" -cert "${WORKDIR}/tls-cert.pem" \
        -key "${WORKDIR}/tls-key.pem" -WWW -quiet >"${WORKDIR}/s_server.log" 2>&1 ) &
    SRV_PIDS="${SRV_PIDS} $!"
    sleep 1

    TLS_BASE="https://127.0.0.1:${TLS_PORT}/apk/aarch64_cortex-a53"
    TLS_PUBKEY_URL="https://127.0.0.1:${TLS_PORT}/apk/keys/tailscale.pem"
    if sh "${PROBE_FEED}" "${TLS_BASE}" "${TLS_PUBKEY_URL}" "v1.98.8" >"${WORKDIR}/probe-cert.log" 2>&1; then
        log_fail "probe-feed.sh unexpectedly PASSED against a self-signed-cert HTTPS server -- TLS/cert check is not real"
    else
        log_info "OK: probe-feed.sh correctly REJECTS an invalid (self-signed) TLS certificate"
        assert_contains "cert failure is specifically labeled a TLS/cert problem (not a generic network failure)" \
            "$(cat "${WORKDIR}/probe-cert.log")" "TLS/cert validity check FAILED"
    fi
else
    log_info "SKIP: openssl s_server unavailable in this environment -- TLS/cert live test skipped (structural grep below still covers the cert-detection branch)"
    CERT_TEST_OK=0
fi

if [ "${CERT_TEST_OK}" -eq 0 ]; then
    assert_contains "probe-feed.sh source distinguishes certificate errors (structural fallback)" \
        "$(cat "${PROBE_FEED}")" "certificate"
fi

# RED proof: a plain unreachable host must NOT be mislabeled as a cert
# failure (the grep for "certificate" must be specific, not overbroad).
if sh "${PROBE_FEED}" "http://127.0.0.1:1/apk/aarch64_cortex-a53" "http://127.0.0.1:1/apk/keys/tailscale.pem" "v1.98.8" >"${WORKDIR}/probe-unreachable.log" 2>&1; then
    log_fail "probe-feed.sh unexpectedly PASSED against an unreachable host"
else
    log_info "OK: probe-feed.sh correctly fails against an unreachable host"
    assert_not_contains "an unreachable-host failure is NOT mislabeled as a cert problem" \
        "$(cat "${WORKDIR}/probe-unreachable.log")" "TLS/cert validity check FAILED"
fi

harness_finish "tests/apk/failure-isolation.sh"
