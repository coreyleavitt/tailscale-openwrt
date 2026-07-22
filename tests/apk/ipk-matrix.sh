#!/bin/sh
# tests/apk/ipk-matrix.sh
#
# Slice C1a test (RFC docs/rfc-apk-builds.md §6): the 4 hand-written ipk
# build jobs in .github/workflows/build-tailscale.yaml (build-mips,
# build-aarch64, build-arm7, build-mipsel) were collapsed into a single
# `strategy: matrix` job (`build-ipk`) driven by arches.json via the A5a
# select-matrix job/scripts/select-matrix.sh -- a pure refactor: same
# `docker build`/Dockerfile ipk-stage invocation per arch, only the arch
# string's source changed (hardcoded literal -> arches.json). Two checks:
#
#   1. Structural: the workflow YAML no longer has the 4 old hand-written
#      jobs, has exactly one matrix job driving ipk builds off
#      needs.select-matrix.outputs.arches, and the release job's `needs`/
#      output references were repointed at it. Also asserts the matrix
#      actually expands (scripts/select-matrix.sh workflow_dispatch) to the
#      same 4 arch names the old hand-written jobs used.
#
#   2. Empirical (the strongest guard): build the aarch64_cortex-a53 .ipk
#      twice through the real tailscale-package/Dockerfile -- once with the
#      arch string hardcoded exactly as the old build-aarch64 job did, once
#      with the arch string sourced the way the new matrix job sources it
#      (scripts/select-matrix.sh's output, i.e. arches.json) -- and diff the
#      extracted data.tar.gz/control.tar.gz *contents* (not the raw .ipk
#      bytes, which differ only by the pre-existing gzip/tar mtime
#      non-determinism documented in A2).
#
# Uses the shared tests/apk/lib.sh harness (established slice A2).
#
# Usage: sh tests/apk/ipk-matrix.sh [--skip-build]
#   --skip-build   run only the structural/matrix-expansion checks (fast,
#                   no docker build); the empirical build/diff check is
#                   skipped. Useful for a quick RED/GREEN loop.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
WORKFLOW="${REPO_ROOT}/.github/workflows/build-tailscale.yaml"
ARCHES_JSON="${REPO_ROOT}/arches.json"
SELECT_MATRIX="${REPO_ROOT}/scripts/select-matrix.sh"
PKG_DIR="${REPO_ROOT}/tailscale-package"

SKIP_BUILD=0
if [ "${1:-}" = "--skip-build" ]; then
    SKIP_BUILD=1
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
if [ ! -x "${SELECT_MATRIX}" ]; then
    echo "FAIL: ${SELECT_MATRIX} not found or not executable" >&2
    exit 1
fi

# The 4 arch strings the old hand-written jobs hardcoded, one per job
# (build-mips/build-aarch64/build-arm7/build-mipsel), sorted for comparison.
OLD_ARCH_NAMES='["aarch64_cortex-a53","arm_cortex-a7","mips_24kc","mipsel_24kc"]'

# --- 1. structural: workflow job graph ---------------------------------

echo "=== structural: workflow job graph ==="

STRUCT_JSON=$(python3 - "${WORKFLOW}" <<'PYEOF'
import sys, json, yaml

with open(sys.argv[1]) as f:
    doc = yaml.safe_load(f)

jobs = doc.get("jobs", {})
old_names = ["build-mips", "build-aarch64", "build-arm7", "build-mipsel"]
old_present = [n for n in old_names if n in jobs]

# Find candidate matrix ipk-build job(s): a job (other than select-matrix/
# qemu-verify/apk-install-verify, which are A5a's apk-side jobs, and
# build-apk, C1b's sibling apk-build matrix job -- same select-matrix
# source and same OPENWRT_ARCH/docker-build shape by design, §4.6) whose
# strategy.matrix.arch references needs.select-matrix.outputs.arches, and
# whose steps shell out to `docker build` with an OPENWRT_ARCH build-arg.
candidates = []
for name, job in jobs.items():
    if name in ("select-matrix", "qemu-verify", "apk-install-verify", "build-apk", "release"):
        continue
    strategy = job.get("strategy", {}) or {}
    matrix = strategy.get("matrix", {}) or {}
    arch_expr = matrix.get("arch", "")
    if "needs.select-matrix.outputs.arches" not in str(arch_expr):
        continue
    steps_text = json.dumps(job.get("steps", []))
    if "OPENWRT_ARCH" not in steps_text or "docker build" not in steps_text:
        continue
    candidates.append(name)

release = jobs.get("release", {})
release_needs = release.get("needs", [])
if isinstance(release_needs, str):
    release_needs = [release_needs]
release_text = json.dumps(release)

result = {
    "old_present": old_present,
    "candidates": candidates,
    "release_needs": release_needs,
    "release_refs_old": any(
        f"needs.{n}.outputs" in release_text for n in old_names
    ),
}
print(json.dumps(result))
PYEOF
)

OLD_PRESENT=$(echo "${STRUCT_JSON}" | jq -c '.old_present')
CANDIDATES=$(echo "${STRUCT_JSON}" | jq -c '.candidates')
CANDIDATE_COUNT=$(echo "${STRUCT_JSON}" | jq '.candidates | length')
RELEASE_NEEDS=$(echo "${STRUCT_JSON}" | jq -c '.release_needs | sort')
RELEASE_REFS_OLD=$(echo "${STRUCT_JSON}" | jq -r '.release_refs_old')

assert_eq "old hand-written ipk jobs removed" "[]" "${OLD_PRESENT}"
assert_eq "exactly one matrix job drives ipk builds off select-matrix" "1" "${CANDIDATE_COUNT}"

if [ "${CANDIDATE_COUNT}" = "1" ]; then
    IPK_JOB=$(echo "${CANDIDATES}" | jq -r '.[0]')
    echo "  -> matrix ipk job: ${IPK_JOB}"
    RELEASE_NEEDS_IPK=$(echo "${RELEASE_NEEDS}" | jq --arg j "${IPK_JOB}" 'index($j) != null')
    assert_eq "release job needs the matrix ipk job" "true" "${RELEASE_NEEDS_IPK}"
else
    log_fail "cannot uniquely identify the matrix ipk job (candidates: ${CANDIDATES})"
fi

assert_eq "release job no longer references old per-arch job outputs" "false" "${RELEASE_REFS_OLD}"

echo

# --- 2. matrix expansion equivalence ------------------------------------

echo "=== matrix expansion: workflow_dispatch (release path) ==="

DISPATCH_NAMES=$("${SELECT_MATRIX}" workflow_dispatch "${ARCHES_JSON}" | jq -c '[.[].name] | sort')
assert_eq "workflow_dispatch matrix == old hand-written 4-arch set" "${OLD_ARCH_NAMES}" "${DISPATCH_NAMES}"

RELEASE_EVENT_NAMES=$("${SELECT_MATRIX}" release "${ARCHES_JSON}" | jq -c '[.[].name] | sort')
assert_eq "release-event matrix == old hand-written 4-arch set" "${OLD_ARCH_NAMES}" "${RELEASE_EVENT_NAMES}"

echo

# --- 3. empirical: build old-arg-style vs matrix-sourced, diff contents -

if [ "${SKIP_BUILD}" -eq 1 ]; then
    echo "=== empirical build/diff SKIPPED (--skip-build) ==="
    harness_finish "tests/apk/ipk-matrix.sh"
    exit "${FAIL}"
fi

require_cmd docker
require_cmd tar

echo "=== empirical: aarch64_cortex-a53 old-path vs matrix-sourced-path ==="

TEST_VERSION="${IPK_MATRIX_TEST_VERSION:-1.92.2}"
TEST_PKG_RELEASE="${IPK_MATRIX_TEST_PKG_RELEASE:-1}"

# "Old way": the literal string the hand-written build-aarch64 job hardcoded.
OLD_ARCH="aarch64_cortex-a53"

# "New way": resolve the arch the same way the matrix job now does --
# through scripts/select-matrix.sh's output (arches.json), by name.
NEW_ARCH=$("${SELECT_MATRIX}" workflow_dispatch "${ARCHES_JSON}" | jq -r '.[] | select(.name=="aarch64_cortex-a53") | .name')

assert_eq "matrix-sourced arch string matches old hardcoded arch string" "${OLD_ARCH}" "${NEW_ARCH}"

WORKDIR=$(mktemp -d)
trap 'rm -rf "${WORKDIR}"' EXIT

build_and_extract() {
    _label="$1"
    _arch="$2"
    _tag="tailscale-ipk-matrix-test-${_label}:latest"
    _outdir="${WORKDIR}/${_label}"
    mkdir -p "${_outdir}/ipk" "${_outdir}/extracted"

    echo "--- building (${_label}, arch=${_arch}) ---"
    # RFC docs/rfc-apk-arch-coverage.md §5.1/S2: the Dockerfile's `build`
    # stage no longer derives GOARCH from OPENWRT_ARCH's name (hard-fails
    # instead), so it must be passed explicitly.
    _goarch=$(jq -r --arg n "${_arch}" '.[] | select(.name==$n) | .goarch // ""' "${ARCHES_JSON}")
    # RFC docs/rfc-apk-arch-coverage.md §5.1/S3: the `ipk` stage's on-device
    # payload now comes from the repo-root scripts/stage-payload.sh, outside
    # this Dockerfile's own build context (tailscale-package/) -- pass it in
    # as a named additional build context (see the Dockerfile's own note).
    if ! docker build \
        --build-context scripts="${REPO_ROOT}/scripts" \
        --build-arg TAILSCALE_VERSION="${TEST_VERSION}" \
        --build-arg PKG_RELEASE="${TEST_PKG_RELEASE}" \
        --build-arg OPENWRT_ARCH="${_arch}" \
        --build-arg GOARCH="${_goarch}" \
        -t "${_tag}" \
        -f "${PKG_DIR}/Dockerfile" "${PKG_DIR}" >"${_outdir}/build.log" 2>&1; then
        tail -n 60 "${_outdir}/build.log" >&2
        log_fail "${_label}: docker build failed"
        return 1
    fi

    if ! docker run --rm "${_tag}" \
        cat "/tailscale_${TEST_VERSION}_${_arch}.ipk" \
        > "${_outdir}/ipk/tailscale.ipk"; then
        log_fail "${_label}: failed to extract .ipk from image"
        return 1
    fi

    # An OpenWrt .ipk (opkg-build/ipkg-build) is itself a gzipped tar
    # containing debian-binary/data.tar.gz/control.tar.gz -- unlike Debian's
    # ar-based .deb -- so the outer archive is `tar`, not `ar`.
    tar -xzf "${_outdir}/ipk/tailscale.ipk" -C "${_outdir}/extracted"
    for tarball in data.tar.gz control.tar.gz; do
        if [ -f "${_outdir}/extracted/${tarball}" ]; then
            mkdir -p "${_outdir}/extracted/${tarball%.tar.gz}"
            tar -xzf "${_outdir}/extracted/${tarball}" -C "${_outdir}/extracted/${tarball%.tar.gz}"
        else
            log_fail "${_label}: ${tarball} missing from extracted .ipk"
        fi
    done
}

build_and_extract "old" "${OLD_ARCH}"
build_and_extract "new" "${NEW_ARCH}"

for tarball in data control; do
    OLD_DIR="${WORKDIR}/old/extracted/${tarball}"
    NEW_DIR="${WORKDIR}/new/extracted/${tarball}"
    if [ -d "${OLD_DIR}" ] && [ -d "${NEW_DIR}" ]; then
        if DIFF_OUT=$(diff -rq "${OLD_DIR}" "${NEW_DIR}" 2>&1); then
            log_info "OK: ${tarball}.tar.gz contents byte-identical (old-path vs matrix-sourced-path)"
        else
            log_fail "${tarball}.tar.gz contents differ:
${DIFF_OUT}"
        fi
    else
        log_fail "${tarball}: extracted dir missing for comparison (old=${OLD_DIR}, new=${NEW_DIR})"
    fi
done

# --- sysupgrade keep-list: /etc/tailscale/ survives a firmware upgrade ---
# Same fix as the apk stage (tests/apk/mkpkg.sh): the ipk payload must ship
# /lib/upgrade/keep.d/tailscale so OpenWrt's sysupgrade preserves the whole
# /etc/tailscale/ dir (tailscaled.state + derpmap.cached.json) across a
# firmware upgrade, instead of wiping the node's Tailscale identity.
KEEP_FILE="${WORKDIR}/new/extracted/data/lib/upgrade/keep.d/tailscale"
if [ -f "${KEEP_FILE}" ]; then
    log_info "OK: ipk data.tar.gz contains ./lib/upgrade/keep.d/tailscale"
    KEEP_CONTENT=$(cat "${KEEP_FILE}")
    assert_eq "keep.d/tailscale content is '/etc/tailscale/'" "/etc/tailscale/" "${KEEP_CONTENT}"
else
    log_fail "ipk data.tar.gz missing ./lib/upgrade/keep.d/tailscale (${KEEP_FILE} not found)"
fi

docker rmi tailscale-ipk-matrix-test-old:latest tailscale-ipk-matrix-test-new:latest >/dev/null 2>&1 || true

harness_finish "tests/apk/ipk-matrix.sh"
