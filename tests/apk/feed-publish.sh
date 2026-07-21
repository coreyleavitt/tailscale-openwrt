#!/bin/sh
# tests/apk/feed-publish.sh
#
# Slice C3 test (RFC docs/rfc-apk-builds.md §4.3, §6 slice C3): the publish
# job's ASSEMBLY/GUARD LOGIC, testable entirely locally against a plain
# `python3 -m http.server` -- no live GitHub Pages deploy required (the C0
# human gate is orthogonal to this test). Exercises scripts/feed-guard.sh's
# three subcommands directly, plus structural assertions on the new
# `publish-feed` workflow job.
#
#   1. Structural: `publish-feed` exists, carries the `apk-feed-publish`
#      concurrency group (cancel-in-progress: false), least-privilege
#      permissions (pages:write/id-token:write ONLY -- no contents:write/
#      attestations:write, which stay on the separate `release` job, C4),
#      is gated to workflow_dispatch, and the workflow YAML parses.
#   2. Monotonicity guard (`feed-guard.sh check-monotonic`): bootstrap
#      (no live index) is a hard error WITHOUT --force (an untrusted feed
#      host's 404 is not a guaranteed "truly absent", so it gets no more of
#      a free pass than any other failure mode) and ALLOWED with --force, a
#      strictly-higher version is allowed, a version <= live is REJECTED
#      without --force and ALLOWED with --force, and a genuine network
#      failure (server unreachable, not a 404) hard-errors distinctly rather
#      than silently allowing.
#   3. Last-N retention planning (`feed-guard.sh plan-retention`): a fresh
#      publish starts a single-entry list; publishing on top of existing
#      history keeps prior blob filenames (not just the newest); the list
#      is capped at N (oldest dropped); republishing an already-retained
#      filename does not duplicate it.
#   4. Index-walk / integrity (`feed-guard.sh verify-tree`): build a real
#      signed feed for one arch (apk mkpkg/mkndx + scripts/adb-sign.py,
#      signed with a freshly generated EC key via `openssl dgst -sign` --
#      byte-for-byte the same EVP_DigestSign(sha512)->DER path imprimatur's
#      /sign/ec uses, RFC §4.2a/§B0 -- this test is about publish/serving
#      integrity, not re-proving the imprimatur signing round-trip, which is
#      C2's job and already covered by tests/apk/sign-verify.sh), serve it
#      via a local HTTP server, and assert: the served packages.adb matches
#      what was built, and every referenced .apk resolves with a hash
#      matching what apk's own tooling computes for it. RED proof: corrupt
#      the served blob on disk after building the index and assert
#      verify-tree correctly REJECTS it (propagation-skew / corruption
#      detection is not vacuous).
#
# Usage: sh tests/apk/feed-publish.sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
WORKFLOW="${REPO_ROOT}/.github/workflows/build-tailscale.yaml"
PKG_DIR="${REPO_ROOT}/tailscale-package"
FEED_GUARD="${REPO_ROOT}/scripts/feed-guard.sh"
ADB_SIGN_PY="${REPO_ROOT}/scripts/adb-sign.py"

# shellcheck source=tests/apk/lib.sh
. "${SCRIPT_DIR}/lib.sh"

require_cmd docker
require_cmd jq
require_cmd python3
require_cmd openssl
require_cmd curl

if [ ! -f "${WORKFLOW}" ]; then
    echo "FAIL: ${WORKFLOW} not found" >&2
    exit 1
fi
if [ ! -x "${FEED_GUARD}" ] && [ ! -f "${FEED_GUARD}" ]; then
    echo "FAIL: ${FEED_GUARD} not found" >&2
    exit 1
fi

WORKDIR=$(mktemp -d)
SRV_PID=""
cleanup() {
    if [ -n "${SRV_PID}" ]; then kill "${SRV_PID}" >/dev/null 2>&1 || true; fi
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. structural: publish-feed job shape
# ---------------------------------------------------------------------------
echo "=== structural: publish-feed workflow job ==="

STRUCT_JSON=$(python3 - "${WORKFLOW}" <<'PYEOF'
import sys, json, yaml

with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)

jobs = doc.get("jobs", {}) or {}
result = {"yaml_ok": True}
result["has_publish_feed"] = "publish-feed" in jobs

pf = jobs.get("publish-feed", {}) or {}

def needs_list(job):
    n = job.get("needs", [])
    if isinstance(n, str):
        n = [n]
    return list(n)

result["publish_needs"] = sorted(needs_list(pf))

conc = pf.get("concurrency", {}) or {}
result["concurrency_group"] = conc.get("group")
result["concurrency_cancel_in_progress"] = conc.get("cancel-in-progress")

perms = pf.get("permissions", {}) or {}
result["permissions"] = perms
result["perms_pages_write"] = perms.get("pages") == "write"
result["perms_id_token_write"] = perms.get("id-token") == "write"
result["perms_no_contents"] = "contents" not in perms
result["perms_no_attestations"] = "attestations" not in perms
result["perms_exact_two_keys"] = sorted(perms.keys()) == ["id-token", "pages"]

result["gated_workflow_dispatch"] = "workflow_dispatch" in str(pf.get("if", ""))

steps = pf.get("steps", []) or []
uses_list = [str(s.get("uses", "")) for s in steps]
result["has_upload_pages_artifact"] = any("upload-pages-artifact" in u for u in uses_list)
result["has_deploy_pages"] = any("deploy-pages" in u for u in uses_list)

# release job must stay untouched / separate: publish-feed never in
# release's needs, release never in publish-feed's needs, release keeps its
# own broader permissions (contents/attestations) -- that separation is the
# whole point of C3's least-privilege bullet.
rel = jobs.get("release", {}) or {}
result["release_needs"] = sorted(needs_list(rel))
result["release_needs_publish_feed"] = "publish-feed" in needs_list(rel)
result["publish_feed_needs_release"] = "release" in needs_list(pf)
rel_perms = rel.get("permissions", {}) or {}
result["release_has_contents_write"] = rel_perms.get("contents") == "write"

print(json.dumps(result))
PYEOF
)

assert_eq "workflow YAML parses" "true" "$(echo "${STRUCT_JSON}" | jq -r '.yaml_ok')"
assert_eq "publish-feed job present" "true" "$(echo "${STRUCT_JSON}" | jq -r '.has_publish_feed')"

assert_eq "concurrency group == apk-feed-publish" "apk-feed-publish" \
    "$(echo "${STRUCT_JSON}" | jq -r '.concurrency_group')"
assert_eq "concurrency cancel-in-progress == false" "false" \
    "$(echo "${STRUCT_JSON}" | jq -r '.concurrency_cancel_in_progress')"

assert_eq "permissions: pages: write" "true" "$(echo "${STRUCT_JSON}" | jq -r '.perms_pages_write')"
assert_eq "permissions: id-token: write" "true" "$(echo "${STRUCT_JSON}" | jq -r '.perms_id_token_write')"
assert_eq "permissions: no contents:write (least-privilege, §4.3)" "true" \
    "$(echo "${STRUCT_JSON}" | jq -r '.perms_no_contents')"
assert_eq "permissions: no attestations:write (least-privilege, §4.3)" "true" \
    "$(echo "${STRUCT_JSON}" | jq -r '.perms_no_attestations')"
assert_eq "permissions: exactly {pages, id-token} -- nothing extra accrued" "true" \
    "$(echo "${STRUCT_JSON}" | jq -r '.perms_exact_two_keys')"

assert_eq "publish-feed gated to workflow_dispatch (no accidental PR publish)" "true" \
    "$(echo "${STRUCT_JSON}" | jq -r '.gated_workflow_dispatch')"

assert_eq "uses actions/upload-pages-artifact" "true" "$(echo "${STRUCT_JSON}" | jq -r '.has_upload_pages_artifact')"
assert_eq "uses actions/deploy-pages" "true" "$(echo "${STRUCT_JSON}" | jq -r '.has_deploy_pages')"

assert_eq "release job untouched: still needs only build-ipk" '["build-ipk"]' \
    "$(echo "${STRUCT_JSON}" | jq -c '.release_needs')"
assert_eq "release does NOT need publish-feed (separate deploys, C4 attaches later)" "false" \
    "$(echo "${STRUCT_JSON}" | jq -r '.release_needs_publish_feed')"
assert_eq "publish-feed does NOT need release (no cross-dependency)" "false" \
    "$(echo "${STRUCT_JSON}" | jq -r '.publish_feed_needs_release')"
assert_eq "release keeps its own contents:write (unaffected by publish-feed's least-privilege)" "true" \
    "$(echo "${STRUCT_JSON}" | jq -r '.release_has_contents_write')"

echo

# ---------------------------------------------------------------------------
# apk-tools binary, needed for check-monotonic/verify-tree (adbdump/mkndx)
# ---------------------------------------------------------------------------
echo "=== extracting pinned apk-tools binary ==="
BIN_DIR="${WORKDIR}/bin"
extract_apk_tools_binary "${BIN_DIR}" "${PKG_DIR}"
PATH="${BIN_DIR}:${PATH}"
export PATH
apk --version >&2

mk_index() {
    # mk_index <version> <out_adb> -- a tiny single-package index at the
    # given tailscale version, arch is irrelevant to guard/retention logic.
    _ver="$1"; _out="$2"
    mkdir -p "${WORKDIR}/pkgroot-empty"
    apk mkpkg --allow-untrusted --info "name:tailscale" --info "version:${_ver}" \
        --info "arch:aarch64_cortex-a53" --files "${WORKDIR}/pkgroot-empty" \
        --output "${WORKDIR}/idx-${_ver}.apk" >/dev/null
    apk mkndx --allow-untrusted --compression none --output "${_out}" "${WORKDIR}/idx-${_ver}.apk" >/dev/null
}

echo

# ---------------------------------------------------------------------------
# 2. monotonicity guard
# ---------------------------------------------------------------------------
echo "=== monotonicity guard (feed-guard.sh check-monotonic) ==="

mk_index "1.98.8-r1" "${WORKDIR}/live.adb"
mk_index "1.99.0-r1" "${WORKDIR}/new_higher.adb"
mk_index "1.98.8-r1" "${WORKDIR}/new_same.adb"
mk_index "1.98.0-r1" "${WORKDIR}/new_lower.adb"

# -- RED proof: before this slice, no feed-guard.sh existed at all, so every
# one of these invocations would fail with "command not found" rather than a
# real allow/reject decision. The negative behaviors below (reject without
# --force) are the load-bearing "guard actually guards" proof; the corrupt-
# blob RED proof for verify-tree follows in section 4.

# check_monotonic_rc description new_adb live_src [extra feed-guard args...]
# -> prints the actual exit code (0/1/2) to stdout, output/diagnostics to
# WORKDIR/fg-out.log. Capturing the real exit code (rather than just
# true/false) is what lets the tests below distinguish "rejected" (1) from
# "hard error" (2), not just "succeeded or not".
check_monotonic_rc() {
    _new="$1"; _live="$2"; shift 2
    if sh "${FEED_GUARD}" check-monotonic "${_new}" "${_live}" "$@" >"${WORKDIR}/fg-out.log" 2>&1; then
        echo 0
    else
        echo "$?"
    fi
}

RC=$(check_monotonic_rc "${WORKDIR}/new_higher.adb" "${WORKDIR}/does-not-exist.adb")
assert_eq "bootstrap (no live index) WITHOUT --force: refused (exit 2, hard error -- M10: an untrusted feed host's 404 is not a guaranteed 'truly absent')" "2" "${RC}"
assert_contains "bootstrap-without-force message tells the operator to pass --force" \
    "$(cat "${WORKDIR}/fg-out.log")" "--force"

RC=$(check_monotonic_rc "${WORKDIR}/new_higher.adb" "${WORKDIR}/does-not-exist.adb" --force)
assert_eq "bootstrap (no live index) WITH --force: allowed (exit 0, deliberate first publish)" "0" "${RC}"

RC=$(check_monotonic_rc "${WORKDIR}/new_higher.adb" "${WORKDIR}/live.adb")
assert_eq "strictly higher version: allowed (exit 0)" "0" "${RC}"

RC=$(check_monotonic_rc "${WORKDIR}/new_same.adb" "${WORKDIR}/live.adb")
assert_eq "same version as live, no --force: rejected (exit 1)" "1" "${RC}"

RC=$(check_monotonic_rc "${WORKDIR}/new_lower.adb" "${WORKDIR}/live.adb")
assert_eq "lower version than live, no --force: rejected (exit 1)" "1" "${RC}"

RC=$(check_monotonic_rc "${WORKDIR}/new_lower.adb" "${WORKDIR}/live.adb" --force)
assert_eq "lower version than live, WITH --force: allowed (deliberate backfill override, exit 0)" "0" "${RC}"

# Genuine network failure (nothing listening) must hard-error distinctly
# (exit 2) -- never silently treated as "no live index yet" (loud-failure
# discipline, RFC guiding constraint #2).
RC=$(check_monotonic_rc "${WORKDIR}/new_higher.adb" "http://127.0.0.1:1/packages.adb")
assert_eq "unreachable live-index URL: hard error (exit 2, NOT bootstrap-allowed)" "2" "${RC}"
assert_contains "hard-error message names the real cause (not a silent bootstrap)" \
    "$(cat "${WORKDIR}/fg-out.log")" "refusing to guess"

echo

# ---------------------------------------------------------------------------
# 3. last-N retention planning
# ---------------------------------------------------------------------------
echo "=== last-N retention planning (feed-guard.sh plan-retention) ==="

FRESH=$(sh "${FEED_GUARD}" plan-retention "${WORKDIR}/no-retained.json" "tailscale-1.99.0-r1.apk")
assert_eq "fresh publish (no live retained.json): single-entry list" \
    '["tailscale-1.99.0-r1.apk"]' "${FRESH}"

printf '%s' '["tailscale-1.98.8-r1.apk","tailscale-1.98.7-r1.apk"]' > "${WORKDIR}/retained-2.json"
KEPT_2=$(sh "${FEED_GUARD}" plan-retention "${WORKDIR}/retained-2.json" "tailscale-1.99.0-r1.apk")
assert_contains "publish on top of history: new version present" "${KEPT_2}" "tailscale-1.99.0-r1.apk"
assert_contains "publish on top of history: PRIOR blob(s) retained (not latest-only)" "${KEPT_2}" "tailscale-1.98.8-r1.apk"
assert_contains "publish on top of history: 2nd-prior blob also retained (N=3 default)" "${KEPT_2}" "tailscale-1.98.7-r1.apk"

printf '%s' '["tailscale-1.98.8-r1.apk","tailscale-1.98.7-r1.apk","tailscale-1.98.6-r1.apk"]' > "${WORKDIR}/retained-3.json"
KEPT_CAP=$(sh "${FEED_GUARD}" plan-retention "${WORKDIR}/retained-3.json" "tailscale-1.99.0-r1.apk")
assert_not_contains "cap at N=3: oldest blob (1.98.6) dropped" "${KEPT_CAP}" "tailscale-1.98.6-r1.apk"
assert_contains "cap at N=3: newest prior blob (1.98.8) still retained" "${KEPT_CAP}" "tailscale-1.98.8-r1.apk"
COUNT_CAP=$(echo "${KEPT_CAP}" | jq 'length')
assert_eq "cap at N=3: list length is exactly 3" "3" "${COUNT_CAP}"

printf '%s' '["tailscale-1.98.8-r1.apk"]' > "${WORKDIR}/retained-dup.json"
DEDUP=$(sh "${FEED_GUARD}" plan-retention "${WORKDIR}/retained-dup.json" "tailscale-1.98.8-r1.apk")
DEDUP_COUNT=$(echo "${DEDUP}" | jq 'length')
assert_eq "republishing an already-retained filename does not duplicate it" "1" "${DEDUP_COUNT}"

# L11 regression: an invalid-JSON live retention manifest hits die() from
# INSIDE the "ok" fetch branch -- before the fix, that ran exit 2 before the
# cleanup below it ever ran, leaking the mktemp -d WORK dir. Point TMPDIR at
# a private, empty scratch directory for this one call so a leaked WORK dir
# is directly observable.
RETENTION_TMP="${WORKDIR}/retention-tmpdir-check"
mkdir -p "${RETENTION_TMP}"
printf 'not a json array' > "${WORKDIR}/retained-bad.json"
if TMPDIR="${RETENTION_TMP}" sh "${FEED_GUARD}" plan-retention "${WORKDIR}/retained-bad.json" "tailscale-1.99.0-r1.apk" \
        >"${WORKDIR}/plan-retention-badjson.log" 2>&1
then
    RC=0
else
    RC=$?
fi
assert_eq "plan-retention on invalid-JSON live manifest: hard error (exit 2)" "2" "${RC}"
assert_eq "plan-retention cleans up its mktemp WORK dir even on the die() validation-failure path (no leak, L11)" "" \
    "$(ls "${RETENTION_TMP}" 2>/dev/null)"

echo

# ---------------------------------------------------------------------------
# 4. index-walk / integrity (real signed feed, served locally)
# ---------------------------------------------------------------------------
echo "=== index-walk / integrity (feed-guard.sh verify-tree) ==="

TREE="${WORKDIR}/tree"
mkdir -p "${TREE}"

apk mkpkg --allow-untrusted --info "name:tailscale" --info "version:1.98.8-r1" \
    --info "arch:aarch64_cortex-a53" --files "${WORKDIR}/pkgroot-empty" \
    --output "${TREE}/tailscale-1.98.8-r1.apk" >/dev/null
apk mkndx --allow-untrusted --compression none --output "${TREE}/packages.adb" "${TREE}"/*.apk >/dev/null

# Sign it for real -- same EVP_DigestSign(sha512)->DER byte path imprimatur's
# /sign/ec uses (B0 spike), via a freshly generated local EC key rather than
# a CI-local imprimatur container: this test is about publish/serving
# integrity, not re-proving the signing round-trip (that's C2's job,
# tests/apk/sign-verify.sh, already hermetically proven end-to-end).
openssl ecparam -genkey -name prime256v1 -noout -out "${WORKDIR}/key.pem" 2>/dev/null
openssl ec -in "${WORKDIR}/key.pem" -pubout -out "${WORKDIR}/pub.pem" 2>/dev/null
python3 "${ADB_SIGN_PY}" preimage "${TREE}/packages.adb" "${WORKDIR}/pub.pem" "${WORKDIR}/preimage.bin" 2>/dev/null
openssl dgst -sha512 -sign "${WORKDIR}/key.pem" -out "${WORKDIR}/sig.der" "${WORKDIR}/preimage.bin"
python3 "${ADB_SIGN_PY}" assemble "${TREE}/packages.adb" "${WORKDIR}/pub.pem" "${WORKDIR}/sig.der" "${WORKDIR}/signed.adb" 2>/dev/null
mv "${WORKDIR}/signed.adb" "${TREE}/packages.adb"

MAGIC=$(head -c4 "${TREE}/packages.adb")
assert_eq "built feed is a real signed 'ADB.' index" "ADB." "${MAGIC}"

PORT=18475
( cd "${TREE}" && exec python3 -m http.server "${PORT}" >"${WORKDIR}/httpd.log" 2>&1 ) &
SRV_PID=$!
_i=0
while [ "${_i}" -lt 20 ]; do
    if curl -fsS -o /dev/null "http://127.0.0.1:${PORT}/packages.adb" 2>/dev/null; then break; fi
    _i=$((_i + 1)); sleep 0.25
done

if sh "${FEED_GUARD}" verify-tree "${TREE}" "http://127.0.0.1:${PORT}" >"${WORKDIR}/verify-ok.log" 2>&1; then
    log_info "OK: verify-tree passes against the freshly served, uncorrupted tree"
    assert_contains "verify-tree confirms served packages.adb matches the built tree" \
        "$(cat "${WORKDIR}/verify-ok.log")" "byte-identical"
    assert_contains "verify-tree confirms the referenced .apk resolves with a matching hash" \
        "$(cat "${WORKDIR}/verify-ok.log")" "resolves with matching hash"
else
    log_fail "verify-tree unexpectedly FAILED against an uncorrupted, freshly served tree: $(cat "${WORKDIR}/verify-ok.log")"
fi

# RED proof: corrupt the served blob ON DISK (simulating CDN propagation
# skew / storage corruption) and assert verify-tree correctly rejects it --
# proves the hash walk is a real check, not a vacuous pass.
printf 'CORRUPTED-BY-TEST' >> "${TREE}/tailscale-1.98.8-r1.apk"
if sh "${FEED_GUARD}" verify-tree "${TREE}" "http://127.0.0.1:${PORT}" >"${WORKDIR}/verify-corrupt.log" 2>&1; then
    log_fail "verify-tree unexpectedly PASSED against a corrupted served blob -- hash walk is not real: $(cat "${WORKDIR}/verify-corrupt.log")"
else
    log_info "OK: verify-tree correctly REJECTS a corrupted served blob (RED proof: propagation-skew detection is real)"
fi

kill "${SRV_PID}" >/dev/null 2>&1 || true
SRV_PID=""

harness_finish "tests/apk/feed-publish.sh"
