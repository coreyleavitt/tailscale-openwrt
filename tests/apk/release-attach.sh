#!/bin/sh
# tests/apk/release-attach.sh
#
# Slice C4 test (RFC docs/rfc-apk-builds.md §4.3, §6 slice C4): structural
# checks over .github/workflows/build-tailscale.yaml asserting the apk
# release-asset-attach path exists and is shaped correctly, without a live
# release:
#
#   (a) a job downloads the apk-<arch> artifacts (C1b) and its
#       softprops/action-gh-release `files:` list includes the built
#       `.apk`s and the pubkey `.pem`.
#   (b) `.apk` subjects are covered by attest-build-provenance (either a
#       glob spanning both extensions, or a second attest step) -- and the
#       existing ipk attest step's `subject-path: packages/*.ipk` is
#       untouched (byte-unchanged ipk discipline).
#   (c) the apk release-asset-attach job's permissions include
#       `contents: write` and `attestations: write`, and it is a job
#       SEPARATE from `publish-feed` (C3, which must stay pages-scoped
#       only -- no contents/attestations creep into that job, no
#       pages/id-token creep into this one).
#   (d) the workflow YAML parses (well-formed).
#
# Also asserts the pre-existing `release` job (ipk) is untouched: same
# `needs`, same permissions, same `subject-path: packages/*.ipk`, same
# `tag_name`/`files:` shape -- the apk attach path must be additive, never
# a rewrite of the ipk path (RFC discipline: "keep ipk release
# assets/behavior byte-unchanged").
#
# Uses the shared tests/apk/lib.sh harness (established slice A2).
#
# Usage: sh tests/apk/release-attach.sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
WORKFLOW="${REPO_ROOT}/.github/workflows/build-tailscale.yaml"

# shellcheck source=tests/apk/lib.sh
. "${SCRIPT_DIR}/lib.sh"

require_cmd jq
require_cmd python3

if [ ! -f "${WORKFLOW}" ]; then
    echo "FAIL: ${WORKFLOW} not found" >&2
    exit 1
fi

STRUCT_JSON=$(python3 - "${WORKFLOW}" <<'PYEOF'
import sys, json, yaml

with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)

result = {"yaml_ok": True}
jobs = doc.get("jobs", {}) or {}


def needs_list(job):
    n = job.get("needs", [])
    if isinstance(n, str):
        n = [n]
    return list(n)


def steps_text(job):
    return json.dumps(job.get("steps", []))


release = jobs.get("release", {}) or {}
publish_feed = jobs.get("publish-feed", {}) or {}

# --- find the apk release-asset-attach job -----------------------------
# A job (other than `release` itself and `publish-feed`) whose steps
# reference downloading apk-* artifacts AND invoke
# softprops/action-gh-release.
candidates = []
for name, job in jobs.items():
    if name in ("release", "publish-feed"):
        continue
    txt = steps_text(job)
    uses_gh_release = "softprops/action-gh-release" in txt
    downloads_apk_artifacts = ("apk-*" in txt) or ("apk-${{" in txt)
    if uses_gh_release and downloads_apk_artifacts:
        candidates.append(name)

result["attach_candidates"] = candidates
result["attach_candidate_count"] = len(candidates)

attach_job = {}
attach_name = candidates[0] if len(candidates) == 1 else None
if attach_name:
    attach_job = jobs.get(attach_name, {}) or {}

result["attach_job_name"] = attach_name

# (a) files: list includes *.apk and the pubkey .pem
attach_txt = steps_text(attach_job)
result["attach_files_include_apk"] = ".apk" in attach_txt
result["attach_files_include_pem"] = ".pem" in attach_txt

# (b) attest coverage for .apk: either a single attest step whose
# subject-path (possibly multi-line) mentions both .ipk and .apk, or two
# separate attest-build-provenance steps (one per job) together covering
# both extensions.
def attest_subject_paths(job):
    paths = []
    for step in job.get("steps", []) or []:
        if "attest-build-provenance" in str(step.get("uses", "")):
            sp = str((step.get("with", {}) or {}).get("subject-path", ""))
            paths.append(sp)
    return paths

release_attest = attest_subject_paths(release)
attach_attest = attest_subject_paths(attach_job)
all_attest = release_attest + attach_attest

result["release_attest_subject_paths"] = release_attest
result["attach_attest_subject_paths"] = attach_attest
result["attest_covers_ipk"] = any(".ipk" in p for p in all_attest)
result["attest_covers_apk"] = any(".apk" in p for p in all_attest)
# ipk step itself must be untouched -- still exactly packages/*.ipk, not
# broadened (that would be an ipk-behavior change, not an apk-only add).
result["release_attest_is_unchanged_ipk_only"] = release_attest == ["packages/*.ipk"]

# (c) permissions: attach job has contents+attestations write; publish-feed
# stays pages-scoped only (no contents/attestations creep).
attach_perms = attach_job.get("permissions", {}) or {}
publish_perms = publish_feed.get("permissions", {}) or {}

result["attach_perms"] = attach_perms
result["publish_feed_perms"] = publish_perms
result["attach_has_contents_write"] = attach_perms.get("contents") == "write"
result["attach_has_attestations_write"] = attach_perms.get("attestations") == "write"
result["publish_feed_lacks_contents"] = "contents" not in publish_perms
result["publish_feed_lacks_attestations"] = "attestations" not in publish_perms
result["attach_lacks_pages"] = "pages" not in attach_perms
result["attach_job_is_publish_feed"] = attach_name == "publish-feed"

# ipk `release` job untouched checks
result["release_needs"] = sorted(needs_list(release))
result["release_perms"] = release.get("permissions", {}) or {}
result["release_tag_name"] = str(release.get("steps", [{}])[-1].get("with", {}).get("tag_name", "")) if release.get("steps") else ""

print(json.dumps(result))
PYEOF
)

assert_eq "workflow YAML parses" "true" "$(echo "${STRUCT_JSON}" | jq -r '.yaml_ok')"

echo "=== locate the apk release-asset-attach job ==="
CANDIDATE_COUNT=$(echo "${STRUCT_JSON}" | jq -r '.attach_candidate_count')
assert_eq "exactly one job downloads apk-* artifacts and calls softprops/action-gh-release (besides release/publish-feed)" "1" "${CANDIDATE_COUNT}"

ATTACH_NAME=$(echo "${STRUCT_JSON}" | jq -r '.attach_job_name')
echo "  -> apk release-asset-attach job: ${ATTACH_NAME}"

assert_eq "apk release-asset-attach job is NOT publish-feed (must be a separate job, §4.3)" "false" \
    "$(echo "${STRUCT_JSON}" | jq -r '.attach_job_is_publish_feed')"

echo
echo "=== (a) gh-release upload list includes .apk + pubkey .pem ==="
assert_eq "attach job's gh-release files reference .apk assets" "true" "$(echo "${STRUCT_JSON}" | jq -r '.attach_files_include_apk')"
assert_eq "attach job's gh-release files reference the .pem pubkey" "true" "$(echo "${STRUCT_JSON}" | jq -r '.attach_files_include_pem')"

echo
echo "=== (b) attest-build-provenance covers .apk (glob or second step) ==="
assert_eq "some attest-build-provenance step covers .ipk" "true" "$(echo "${STRUCT_JSON}" | jq -r '.attest_covers_ipk')"
assert_eq "some attest-build-provenance step covers .apk" "true" "$(echo "${STRUCT_JSON}" | jq -r '.attest_covers_apk')"
assert_eq "release job's own attest step is unchanged (still exactly packages/*.ipk)" "true" \
    "$(echo "${STRUCT_JSON}" | jq -r '.release_attest_is_unchanged_ipk_only')"

echo
echo "=== (c) least-privilege job boundary ==="
assert_eq "attach job has contents: write" "true" "$(echo "${STRUCT_JSON}" | jq -r '.attach_has_contents_write')"
assert_eq "attach job has attestations: write" "true" "$(echo "${STRUCT_JSON}" | jq -r '.attach_has_attestations_write')"
assert_eq "attach job has no pages permission" "true" "$(echo "${STRUCT_JSON}" | jq -r '.attach_lacks_pages')"
assert_eq "publish-feed job has no contents permission (stays pages-scoped)" "true" "$(echo "${STRUCT_JSON}" | jq -r '.publish_feed_lacks_contents')"
assert_eq "publish-feed job has no attestations permission (stays pages-scoped)" "true" "$(echo "${STRUCT_JSON}" | jq -r '.publish_feed_lacks_attestations')"

echo
echo "=== ipk release job (release) is untouched ==="
RELEASE_NEEDS=$(echo "${STRUCT_JSON}" | jq -c '.release_needs')
assert_eq "release job still needs exactly [build-ipk]" '["build-ipk"]' "${RELEASE_NEEDS}"

RELEASE_PERMS=$(echo "${STRUCT_JSON}" | jq -c '.release_perms | to_entries | sort')
EXPECTED_RELEASE_PERMS=$(echo '{"contents":"write","id-token":"write","attestations":"write"}' | jq -c 'to_entries | sort')
assert_eq "release job permissions unchanged (contents/id-token/attestations write)" "${EXPECTED_RELEASE_PERMS}" "${RELEASE_PERMS}"

RELEASE_TAG=$(echo "${STRUCT_JSON}" | jq -r '.release_tag_name')
assert_contains "release job's gh-release tag_name still keyed off build-ipk output" "${RELEASE_TAG}" "needs.build-ipk.outputs.version"

harness_finish "tests/apk/release-attach.sh"
