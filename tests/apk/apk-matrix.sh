#!/bin/sh
# tests/apk/apk-matrix.sh
#
# Slice C1b test (RFC docs/rfc-apk-builds.md §6): a SEPARATE apk build
# matrix job (`build-apk`), keyed off the same arches.json/select-matrix
# source as C1a's `build-ipk`, producing arch-namespaced `.apk` artifacts.
# The load-bearing property (RFC §4.6) is that `build-apk` is a DAG
# SIBLING of `build-ipk` -- its own `needs: [select-matrix]`, never
# needs-chained through `build-ipk` and never a step inside it -- so a
# later slice (C5) can make apk failures non-blocking to the ipk release
# purely by changing `if:`/`needs:` wiring, with no restructuring. Four
# checks, all structural (the `apk` Dockerfile stage / build-apk.sh
# build path was already proven empirically in A2/A5b; this slice is
# purely about workflow DAG shape):
#
#   (a) `build-apk` is a matrix job driven by
#       needs.select-matrix.outputs.arches (same source as build-ipk).
#   (b) sibling, not nested: `build-apk` does not appear in `build-ipk`'s
#       `needs` and vice versa; both are independent top-level entries in
#       `jobs:` (never a step-list entry inside the other).
#   (c) each matrix leg uploads an arch-namespaced artifact (name and path
#       both keyed by matrix.arch.name) -- NOT a flat/shared name, which
#       would collide across arches since all four build an identically
#       named tailscale-<version>.apk (RFC §3/§4.3). Also guards against a
#       `merge-multiple: true` download step flattening the apk artifacts.
#   (d) the workflow YAML parses (well-formed).
#
# Optional (--build): actually run `docker build --target apk` for one
# arch (aarch64_cortex-a53) via tailscale-package/build-apk.sh, the exact
# path the new job's steps invoke, and assert a non-empty .apk lands.
# Skipped by default -- the apk stage itself was already proven in A2/A5b
# (adbdump-verified name/version/arch/depends, real install under qemu);
# this slice does not change that stage, only where it's invoked from, so
# a full rebuild adds build time without adding coverage. Pass --build to
# opt in.
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

# (a) matrix driven by needs.select-matrix.outputs.arches
apk_strategy = apk_job.get("strategy", {}) or {}
apk_matrix = apk_strategy.get("matrix", {}) or {}
apk_arch_expr = str(apk_matrix.get("arch", ""))
result["apk_matrix_arch_expr"] = apk_arch_expr
result["apk_matrix_from_select_matrix"] = (
    "needs.select-matrix.outputs.arches" in apk_arch_expr
)

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
# build-apk, check `name:` and `path:` are both keyed by matrix.arch.name
# (so no two matrix legs ever share a name), and confirm the workflow
# nowhere downloads apk-namespaced artifacts with merge-multiple: true
# (that would flatten distinct arches' identically-named .apk files into
# one dir and collide -- RFC §3/§4.3).
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
    "matrix.arch.name" in n for n in result["apk_upload_names"]
) and len(upload_steps) > 0
result["apk_upload_path_arch_namespaced"] = all(
    "matrix.arch.name" in p for p in result["apk_upload_paths"]
) and len(upload_steps) > 0

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

print(json.dumps(result))
PYEOF
)

assert_eq "workflow YAML parses" "true" "$(echo "${STRUCT_JSON}" | jq -r '.yaml_ok')"
assert_eq "build-ipk job present (untouched by this slice)" "true" "$(echo "${STRUCT_JSON}" | jq -r '.has_build_ipk')"
assert_eq "build-apk job present" "true" "$(echo "${STRUCT_JSON}" | jq -r '.has_build_apk')"

assert_eq "build-apk matrix driven by needs.select-matrix.outputs.arches" "true" \
    "$(echo "${STRUCT_JSON}" | jq -r '.apk_matrix_from_select_matrix')"

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
assert_eq "apk artifact name is arch-namespaced (matrix.arch.name)" "true" \
    "$(echo "${STRUCT_JSON}" | jq -r '.apk_upload_name_arch_namespaced')"
assert_eq "apk artifact path is arch-namespaced (matrix.arch.name)" "true" \
    "$(echo "${STRUCT_JSON}" | jq -r '.apk_upload_path_arch_namespaced')"
assert_eq "no merge-multiple flatten of apk-* artifacts anywhere in workflow" "false" \
    "$(echo "${STRUCT_JSON}" | jq -r '.apk_flat_merge_present')"

echo

# --- matrix source equivalence with build-ipk ---------------------------

echo "=== build-apk matrix source == build-ipk matrix source ==="

IPK_ARCH_EXPR=$(python3 - "${WORKFLOW}" <<'PYEOF'
import sys, yaml
with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)
job = doc.get("jobs", {}).get("build-ipk", {}) or {}
matrix = ((job.get("strategy", {}) or {}).get("matrix", {}) or {})
print(str(matrix.get("arch", "")))
PYEOF
)
APK_ARCH_EXPR=$(echo "${STRUCT_JSON}" | jq -r '.apk_matrix_arch_expr')

assert_eq "build-apk and build-ipk read the identical matrix expression" \
    "${IPK_ARCH_EXPR}" "${APK_ARCH_EXPR}"

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
