#!/bin/sh
# tests/apk/apk-matrix.sh
#
# Slice C1b test (RFC docs/rfc-apk-builds.md §6), RESTRUCTURED for slice S4
# (RFC docs/rfc-apk-arch-coverage.md §5.1/§5.3/§5.8): `build-apk` is a
# SEPARATE job from `build-ipk`, producing arch-namespaced `.apk`
# artifacts. The load-bearing DAG property (RFC §4.6) is unchanged --
# `build-apk` is a DAG SIBLING of `build-ipk`, its own
# `needs: [select-matrix]`, never needs-chained through `build-ipk` and
# never a step inside it -- so a later slice can make apk failures
# non-blocking to the ipk release purely by changing `if:`/`needs:` wiring,
# with no restructuring.
#
# S4 restructure: `build-apk` no longer matrixes over the flat arches list
# (that's build-ipk's source, decoupled on purpose now -- ipk must not
# widen). It matrixes over select-matrix's FAMILIES output instead --
# compile ONCE per family (`docker build --target build`), then an in-job
# shell loop packages that family's gated arches host-side via
# scripts/package-apk.sh (RFC §5.3 "no second matrix stage"). The
# Dockerfile `apk` stage this job used to build via `--target apk` was
# DELETED this slice; `docker build --target apk` must not appear anywhere
# in the workflow any more. Checks, all structural (the family-compile +
# host-side-package path itself is proven empirically by
# tests/apk/{mkpkg,install}.sh and this file's own --build one-arch smoke
# test below; this file is purely about workflow DAG/wiring shape):
#
#   (a) `build-apk` is a matrix job driven by
#       needs.select-matrix.outputs.families (NOT .arches -- that's
#       build-ipk's source now, deliberately decoupled).
#   (b) sibling, not nested: `build-apk` does not appear in `build-ipk`'s
#       `needs` and vice versa; both are independent top-level entries in
#       `jobs:` (never a step-list entry inside the other).
#   (c) each matrix leg uploads an arch-namespaced artifact (name and path
#       both keyed by matrix.family.arches[0]) -- NOT a flat/shared name,
#       which would collide across arches since they'd all build an
#       identically named tailscale-<version>.apk (RFC §3/§4.3). Also
#       guards against a `merge-multiple: true` download step flattening
#       the apk artifacts, AND asserts a preceding step hard-fails the job
#       if a family ever carries more than the single gated arch this
#       upload wiring assumes (rather than silently dropping extras).
#   (d) the workflow YAML parses (well-formed); `--target apk` appears
#       nowhere in it any more; build-apk's compile step targets `build`
#       and its packaging step calls scripts/package-apk.sh.
#
# Optional (--build): actually run the family-binary compile
# (`docker build --target build`) + host-side package
# (scripts/package-apk.sh) for one arch (aarch64_cortex-a53) via
# tailscale-package/build-apk.sh (S4-migrated, mirrors the new job's own
# steps), and assert a non-empty .apk lands. Skipped by default -- that
# path is already proven in A2/A5b/S3 (adbdump-verified
# name/version/arch/depends, real install under qemu); this file's default
# run is about workflow DAG shape, not re-proving the build path. Pass
# --build to opt in.
#
# Usage: sh tests/apk/apk-matrix.sh [--build]

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
WORKFLOW="${REPO_ROOT}/.github/workflows/build-tailscale.yaml"
ARCHES_JSON="${REPO_ROOT}/arches.json"
PKG_DIR="${REPO_ROOT}/tailscale-package"

DO_BUILD=0
if [ "${1:-}" = "--build" ]; then
    DO_BUILD=1
fi

# shellcheck source=tests/apk/lib.sh
. "${SCRIPT_DIR}/lib.sh"

require_cmd jq
require_cmd python3

if [ ! -f "${WORKFLOW}" ]; then
    echo "FAIL: ${WORKFLOW} not found" >&2
    exit 1
fi
if [ ! -f "${ARCHES_JSON}" ]; then
    echo "FAIL: ${ARCHES_JSON} not found" >&2
    exit 1
fi

# --- structural: workflow job graph -------------------------------------

echo "=== structural: build-apk is a sibling matrix job to build-ipk ==="

STRUCT_JSON=$(python3 - "${WORKFLOW}" <<'PYEOF'
import sys, json, yaml

with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)

result = {"yaml_ok": True}

jobs = doc.get("jobs", {}) or {}
result["has_build_ipk"] = "build-ipk" in jobs
result["has_build_apk"] = "build-apk" in jobs

def needs_list(job):
    n = job.get("needs", [])
    if isinstance(n, str):
        n = [n]
    return list(n)

apk_job = jobs.get("build-apk", {}) or {}
ipk_job = jobs.get("build-ipk", {}) or {}

apk_needs = needs_list(apk_job)
ipk_needs = needs_list(ipk_job)
result["apk_needs"] = sorted(apk_needs)
result["ipk_needs"] = sorted(ipk_needs)

# (a) S4 restructure: build-apk matrixes over select-matrix's FAMILIES
# output (compile once per family), NOT its flat arches output (that's
# build-ipk's source, unchanged) -- RFC docs/rfc-apk-arch-coverage.md
# §5.1/§5.3/S4.
apk_strategy = apk_job.get("strategy", {}) or {}
apk_matrix = apk_strategy.get("matrix", {}) or {}
apk_family_expr = str(apk_matrix.get("family", ""))
result["apk_matrix_family_expr"] = apk_family_expr
result["apk_matrix_from_select_matrix_families"] = (
    "needs.select-matrix.outputs.families" in apk_family_expr
)
result["apk_matrix_has_no_arch_key"] = "arch" not in apk_matrix

# (b) sibling, not nested: neither job appears in the other's `needs`, and
# each is its own top-level `jobs:` entry (a job can only be referenced via
# `needs:`, so "not a step inside" reduces to: build-apk is not literally
# one of build-ipk's step entries, and both exist as independent job keys
# -- already covered by has_build_ipk/has_build_apk above).
result["apk_needs_ipk"] = "build-ipk" in apk_needs
result["ipk_needs_apk"] = "build-apk" in ipk_needs

apk_steps_text = json.dumps(apk_job.get("steps", []))
ipk_steps_text = json.dumps(ipk_job.get("steps", []))
result["build_apk_is_step_in_ipk"] = "build-apk" in ipk_steps_text
result["build_ipk_is_step_in_apk"] = "build-ipk" in apk_steps_text

# (c) arch-namespaced artifact upload: find upload-artifact steps in
# build-apk, check `name:` and `path:` are both keyed by an arch name (S4:
# matrix.family.arches[0] -- see the build-apk job-level "KNOWN SCOPE
# LIMIT" comment; a family job's upload step is wired for exactly the
# family's one gated arch, guarded by a preceding step that hard-fails if a
# family ever carries more than one), and confirm the workflow nowhere
# downloads apk-namespaced artifacts with merge-multiple: true (that would
# flatten distinct arches' identically-named .apk files into one dir and
# collide -- RFC §3/§4.3).
upload_steps = [
    s for s in apk_job.get("steps", []) or []
    if "upload-artifact" in str(s.get("uses", ""))
]
result["apk_upload_step_count"] = len(upload_steps)
result["apk_upload_names"] = [
    str((s.get("with", {}) or {}).get("name", "")) for s in upload_steps
]
result["apk_upload_paths"] = [
    str((s.get("with", {}) or {}).get("path", "")) for s in upload_steps
]
result["apk_upload_name_arch_namespaced"] = all(
    "matrix.family.arches[0]" in n for n in result["apk_upload_names"]
) and len(upload_steps) > 0
result["apk_upload_path_arch_namespaced"] = all(
    "matrix.family.arches[0]" in p for p in result["apk_upload_paths"]
) and len(upload_steps) > 0

# S4 guard: a preceding step must hard-fail the job if a family ever
# carries more than the 1 gated arch this upload wiring assumes (rather
# than silently uploading only arches[0] and dropping the rest).
apk_run_texts = " ".join(
    str(s.get("run", "")) for s in apk_job.get("steps", []) or []
)
result["apk_has_single_arch_upload_guard"] = (
    "arches" in apk_run_texts and "jq 'length'" in apk_run_texts
)

# Guard: no download-artifact step anywhere in the workflow merge-multiples
# an apk-* artifact pattern into a flat dir.
bad_merge = False
for name, job in jobs.items():
    for step in job.get("steps", []) or []:
        if "download-artifact" not in str(step.get("uses", "")):
            continue
        with_block = step.get("with", {}) or {}
        pattern = str(with_block.get("pattern", ""))
        merge_multiple = with_block.get("merge-multiple", False)
        if merge_multiple in (True, "true") and "apk" in pattern:
            bad_merge = True
result["apk_flat_merge_present"] = bad_merge

# S4: `docker build --target apk` must not appear ANYWHERE in the workflow
# any more -- the Dockerfile stage it targeted was deleted this slice.
result["workflow_has_target_apk"] = "--target apk" in json.dumps(doc) or "target: apk" in json.dumps(doc)

# S4: build-apk's compile step targets `build` (the family binary), not the
# deleted `apk` stage.
apk_run_all = " ".join(str(s.get("run", "")) for s in apk_job.get("steps", []) or [])
result["apk_job_targets_build_stage"] = "--target build" in apk_run_all
result["apk_job_calls_package_apk_sh"] = "package-apk.sh" in apk_run_all

print(json.dumps(result))
PYEOF
)

assert_eq "workflow YAML parses" "true" "$(echo "${STRUCT_JSON}" | jq -r '.yaml_ok')"
assert_eq "build-ipk job present (untouched by this slice)" "true" "$(echo "${STRUCT_JSON}" | jq -r '.has_build_ipk')"
assert_eq "build-apk job present" "true" "$(echo "${STRUCT_JSON}" | jq -r '.has_build_apk')"

assert_eq "build-apk matrix driven by needs.select-matrix.outputs.families (S4)" "true" \
    "$(echo "${STRUCT_JSON}" | jq -r '.apk_matrix_from_select_matrix_families')"
assert_eq "build-apk matrix has no arch key (compiles per family, not per arch)" "true" \
    "$(echo "${STRUCT_JSON}" | jq -r '.apk_matrix_has_no_arch_key')"

assert_eq "build-apk needs == [select-matrix] only" '["select-matrix"]' \
    "$(echo "${STRUCT_JSON}" | jq -c '.apk_needs')"

assert_eq "build-apk NOT needs-chained through build-ipk (sibling, §4.6)" "false" \
    "$(echo "${STRUCT_JSON}" | jq -r '.apk_needs_ipk')"
assert_eq "build-ipk does not need build-apk (build-ipk untouched)" "false" \
    "$(echo "${STRUCT_JSON}" | jq -r '.ipk_needs_apk')"
assert_eq "build-apk is not a step inside build-ipk" "false" \
    "$(echo "${STRUCT_JSON}" | jq -r '.build_apk_is_step_in_ipk')"
assert_eq "build-ipk is not a step inside build-apk" "false" \
    "$(echo "${STRUCT_JSON}" | jq -r '.build_ipk_is_step_in_apk')"

assert_eq "build-apk uploads at least one artifact" "true" \
    "$([ "$(echo "${STRUCT_JSON}" | jq -r '.apk_upload_step_count')" -gt 0 ] && echo true || echo false)"
assert_eq "apk artifact name is arch-namespaced (matrix.family.arches[0])" "true" \
    "$(echo "${STRUCT_JSON}" | jq -r '.apk_upload_name_arch_namespaced')"
assert_eq "apk artifact path is arch-namespaced (matrix.family.arches[0])" "true" \
    "$(echo "${STRUCT_JSON}" | jq -r '.apk_upload_path_arch_namespaced')"
assert_eq "build-apk hard-fails if a family ever has >1 gated arch (upload wiring guard)" "true" \
    "$(echo "${STRUCT_JSON}" | jq -r '.apk_has_single_arch_upload_guard')"
assert_eq "no merge-multiple flatten of apk-* artifacts anywhere in workflow" "false" \
    "$(echo "${STRUCT_JSON}" | jq -r '.apk_flat_merge_present')"

echo

# --- S4: the deleted Dockerfile apk stage is gone from the workflow too ---

echo "=== S4: 'docker build --target apk' no longer appears anywhere in the workflow ==="

assert_eq "workflow nowhere targets the deleted 'apk' Dockerfile stage" "false" \
    "$(echo "${STRUCT_JSON}" | jq -r '.workflow_has_target_apk')"
assert_eq "build-apk's compile step targets the 'build' stage (family binary)" "true" \
    "$(echo "${STRUCT_JSON}" | jq -r '.apk_job_targets_build_stage')"
assert_eq "build-apk's packaging step calls scripts/package-apk.sh (host-side)" "true" \
    "$(echo "${STRUCT_JSON}" | jq -r '.apk_job_calls_package_apk_sh')"

echo

# --- build-apk matrix source is DECOUPLED from build-ipk's (S4) ---------
#
# Before S4, build-apk and build-ipk deliberately shared the identical
# per-arch matrix expression (C1b). S4 decouples them on purpose: build-ipk
# still matrixes over the flat arches output (ipk must not widen, RFC
# non-goals), while build-apk now matrixes over the families output
# (compile once per family). Assert the decoupling directly, rather than
# asserting equality (which would now be testing the wrong invariant).

echo "=== build-apk (families) is deliberately decoupled from build-ipk (arches) ==="

IPK_ARCH_EXPR=$(python3 - "${WORKFLOW}" <<'PYEOF'
import sys, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)
job = doc.get("jobs", {}).get("build-ipk", {}) or {}
matrix = ((job.get("strategy", {}) or {}).get("matrix", {}) or {})
print(str(matrix.get("arch", "")))
PYEOF
)
assert_contains "build-ipk's matrix still reads needs.select-matrix.outputs.arches (unchanged)" \
    "${IPK_ARCH_EXPR}" "needs.select-matrix.outputs.arches"

FAMILY_EXPR=$(echo "${STRUCT_JSON}" | jq -r '.apk_matrix_family_expr')
assert_contains "build-apk's matrix reads needs.select-matrix.outputs.families (S4)" \
    "${FAMILY_EXPR}" "needs.select-matrix.outputs.families"

echo

# --- structural: arm_cortex-a7 softfloat fix (GOARM=5, not hardcoded 7) -----
#
# Regression guard for the live correctness bug: arm_cortex-a7 is OpenWrt's
# BARE, FPU-less Cortex-A7 package arch (distinct from cortex-a7_vfpv4 /
# cortex-a7_neon-vfpv4, which do carry a hard-float ABI). A GOARM=7 Go binary
# emits hardware VFP instructions and SIGILLs on genuinely FPU-less silicon,
# AFTER `apk add` reports success. Checks:
#   (a) arches.json says GOARM=5 (softfloat) for arm_cortex-a7, and the other
#       three arches' goarm/gomips are unchanged.
#   (b) build-apk.sh looks up goarm/gomips per-arch from arches.json and
#       passes them through as explicit --build-arg (rather than letting the
#       Dockerfile guess from the OPENWRT_ARCH name).
#   (c) the Dockerfile's `build` stage declares ARG GOARM/GOMIPS (so it can
#       honor a caller-supplied value) and no longer contains the old
#       hardcode-by-name bug (`grep -q arm_cortex && echo "7"`).

echo "=== structural: arm_cortex-a7 GOARM=5 fix (not hardcoded GOARM=7) ==="

BUILD_APK_SH="${PKG_DIR}/build-apk.sh"
DOCKERFILE="${PKG_DIR}/Dockerfile"

assert_eq "arches.json: arm_cortex-a7 goarm is 5 (softfloat)" "5" \
    "$(jq -r '.[] | select(.name == "arm_cortex-a7") | .goarm' "${ARCHES_JSON}")"
assert_eq "arches.json: aarch64_cortex-a53 goarm unchanged (empty, arm64 ignores it)" "" \
    "$(jq -r '.[] | select(.name == "aarch64_cortex-a53") | .goarm' "${ARCHES_JSON}")"
assert_eq "arches.json: mips_24kc gomips unchanged (softfloat)" "softfloat" \
    "$(jq -r '.[] | select(.name == "mips_24kc") | .gomips' "${ARCHES_JSON}")"
assert_eq "arches.json: mipsel_24kc gomips unchanged (softfloat)" "softfloat" \
    "$(jq -r '.[] | select(.name == "mipsel_24kc") | .gomips' "${ARCHES_JSON}")"
assert_eq "arches.json: mipsel_24kc goarch unchanged (mipsle)" "mipsle" \
    "$(jq -r '.[] | select(.name == "mipsel_24kc") | .goarch' "${ARCHES_JSON}")"
assert_eq "arches.json: aarch64_cortex-a53 goarch unchanged (arm64)" "arm64" \
    "$(jq -r '.[] | select(.name == "aarch64_cortex-a53") | .goarch' "${ARCHES_JSON}")"

if [ ! -f "${BUILD_APK_SH}" ]; then
    echo "FAIL: ${BUILD_APK_SH} not found" >&2
    FAIL=1
fi
if [ ! -f "${DOCKERFILE}" ]; then
    echo "FAIL: ${DOCKERFILE} not found" >&2
    FAIL=1
fi

BUILD_APK_SH_TEXT=$(cat "${BUILD_APK_SH}")
DOCKERFILE_TEXT=$(cat "${DOCKERFILE}")

assert_contains "build-apk.sh looks up .goarm from arches.json" \
    "${BUILD_APK_SH_TEXT}" '.goarm'
assert_contains "build-apk.sh looks up .gomips from arches.json" \
    "${BUILD_APK_SH_TEXT}" '.gomips'
assert_contains "build-apk.sh passes GOARM as an explicit docker --build-arg" \
    "${BUILD_APK_SH_TEXT}" '--build-arg GOARM='
assert_contains "build-apk.sh passes GOMIPS as an explicit docker --build-arg" \
    "${BUILD_APK_SH_TEXT}" '--build-arg GOMIPS='

assert_contains "Dockerfile build stage declares ARG GOARM (honors caller value)" \
    "${DOCKERFILE_TEXT}" 'ARG GOARM'
assert_contains "Dockerfile build stage declares ARG GOMIPS (honors caller value)" \
    "${DOCKERFILE_TEXT}" 'ARG GOMIPS'
assert_contains "Dockerfile go build passes through the GOARM build arg" \
    "${DOCKERFILE_TEXT}" 'GOARM=${GOARM}'
assert_not_contains "Dockerfile no longer hardcodes GOARM=7 by matching the arm_cortex* name" \
    "${DOCKERFILE_TEXT}" 'grep -q arm_cortex'

echo

# --- optional empirical: one-arch real build ------------------------------

if [ "${DO_BUILD}" -eq 0 ]; then
    echo "=== empirical single-arch build SKIPPED (pass --build to opt in) ==="
    harness_finish "tests/apk/apk-matrix.sh"
    exit "${FAIL}"
fi

require_cmd docker

echo "=== empirical: aarch64_cortex-a53 via build-apk.sh (the job's own build path) ==="

TEST_VERSION="${APK_MATRIX_TEST_VERSION:-1.92.2}"
TEST_PKG_RELEASE="${APK_MATRIX_TEST_PKG_RELEASE:-1}"
TEST_ARCH="aarch64_cortex-a53"

WORKDIR=$(mktemp -d)
trap 'rm -rf "${WORKDIR}"' EXIT

(
    cd "${PKG_DIR}"
    "${PKG_DIR}/build-apk.sh" "${TEST_VERSION}" "${TEST_PKG_RELEASE}" "${TEST_ARCH}"
)

BUILT_APK="${PKG_DIR}/packages/${TEST_ARCH}/tailscale-${TEST_VERSION}-r${TEST_PKG_RELEASE}.apk"
if [ -s "${BUILT_APK}" ]; then
    log_info "OK: ${TEST_ARCH} .apk built and non-empty (${BUILT_APK})"
else
    log_fail "${TEST_ARCH} .apk missing or empty at ${BUILT_APK}"
fi

docker rmi "tailscale-apk-${TEST_ARCH}:v${TEST_VERSION}" >/dev/null 2>&1 || true

# --- optional empirical: arm_cortex-a7 actually compiles with GOARM=5 -----
#
# Cheap real-build smoke test for the fix itself: build only the `build`
# stage (Go cross-compile, no apk packaging) for arm_cortex-a7 with GOARM
# sourced from arches.json exactly as build-apk.sh does, and grep the
# Dockerfile's own "Building for GOARCH=... GOARM=... GOMIPS=..." echo out
# of the plain-progress build log to confirm GOARM=5 (softfloat) was what
# actually reached `go build` -- not just what arches.json/build-apk.sh
# *say* should happen.

echo
echo "=== empirical: arm_cortex-a7 go build receives GOARM=5 (build stage only) ==="

ARM7_GOARCH=$(jq -r '.[] | select(.name == "arm_cortex-a7") | .goarch' "${ARCHES_JSON}")
ARM7_GOARM=$(jq -r '.[] | select(.name == "arm_cortex-a7") | .goarm' "${ARCHES_JSON}")
ARM7_LOG="${WORKDIR}/arm7-build.log"

(
    cd "${PKG_DIR}"
    docker build \
        --progress=plain \
        --target build \
        --build-arg TAILSCALE_VERSION="${TEST_VERSION}" \
        --build-arg PKG_RELEASE="${TEST_PKG_RELEASE}" \
        --build-arg OPENWRT_ARCH=arm_cortex-a7 \
        --build-arg GOARCH="${ARM7_GOARCH}" \
        --build-arg GOARM="${ARM7_GOARM}" \
        --build-arg SKIP_UPX=1 \
        -t tailscale-build-smoke-arm_cortex-a7:test \
        -f Dockerfile \
        . > "${ARM7_LOG}" 2>&1
)

if grep -q 'Building for GOARCH=arm GOARM=5 ' "${ARM7_LOG}"; then
    log_info "OK: arm_cortex-a7 build stage compiled with GOARCH=arm GOARM=5"
else
    log_fail "arm_cortex-a7 build stage did not report GOARCH=arm GOARM=5 -- see ${ARM7_LOG}"
fi

docker rmi "tailscale-build-smoke-arm_cortex-a7:test" >/dev/null 2>&1 || true

harness_finish "tests/apk/apk-matrix.sh"
