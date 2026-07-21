#!/bin/sh
# tests/apk/select-matrix.sh
#
# Slice S1b test (RFC docs/rfc-apk-arch-coverage.md §5.8 migration-safety
# gate + §5.3 round-2 P-SEV2/F-SEV2 PR-canary-key fix): scripts/select-matrix.sh
# operates over the now-widened 35-row arches.json (S1b), but must NOT widen
# its own output -- until S2-S4 land, every non-legacy arch would silently
# mis-build (Dockerfile's string-`case` GOARCH derivation defaults to 32-bit
# MIPS). `tier` is the gate: the non-PR branch filters to `tier=="core"`.
#
# No docker/qemu needed -- pure jq/shell, exercising the real (committed)
# arches.json directly, the same style as tests/apk/families.sh.
#
# Covers:
#   1. THE HAZARD, proven directly: naively dumping the widened arches.json
#      (i.e. `jq '.'`, what select-matrix.sh did before S1b's gate) yields
#      35 rows -- the exact bug the tier=="core" filter exists to prevent.
#   2. workflow_dispatch and release (any non-pull_request event) both
#      select EXACTLY the 4 historical `tier=="core"` arches -- not the 35
#      the raw table now has.
#   3. pull_request selects EXACTLY the canary set (mips_24kc), keyed
#      strictly on `canary == true`.
#   4. The A64 over-select regression (round-2 P-SEV2): PR selection count
#      does NOT grow now that arches.json carries four `goarch=="arm64"`
#      rows (one of which -- aarch64_cortex-a53 -- still carries
#      `container_arch == "aarch64"`, the exact field the old, deleted
#      `or .container_arch == "aarch64"` clause keyed on). PR selection is
#      asserted independent of container_arch entirely.
#   5. Every row select-matrix.sh returns for a non-PR event has
#      `tier == "core"` (no extended/infeasible row ever leaks through the
#      gate), and the reverse: no `tier=="core"` arch is ever missing.
#
# Usage: sh tests/apk/select-matrix.sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
SELECT_MATRIX="${REPO_ROOT}/scripts/select-matrix.sh"
ARCHES_JSON="${REPO_ROOT}/arches.json"

# shellcheck source=tests/apk/lib.sh
. "${SCRIPT_DIR}/lib.sh"

require_cmd jq

if [ ! -x "${SELECT_MATRIX}" ]; then
    echo "FAIL: ${SELECT_MATRIX} not found or not executable" >&2
    exit 1
fi
if [ ! -f "${ARCHES_JSON}" ]; then
    echo "FAIL: ${ARCHES_JSON} not found" >&2
    exit 1
fi

CORE_NAMES='["aarch64_cortex-a53","arm_cortex-a7","mips_24kc","mipsel_24kc"]'

# --- 1. the hazard, proven directly -----------------------------------------

echo "=== the hazard: the raw (ungated) table has grown past the 4 legacy arches ==="

RAW_COUNT=$(jq 'length' "${ARCHES_JSON}")
assert_eq "arches.json itself now has 35 rows (S1b's widen)" "35" "${RAW_COUNT}"

if [ "${RAW_COUNT}" -gt 4 ]; then
    log_info "OK: confirms the hazard the tier==core gate exists to prevent (would be ${RAW_COUNT} builds against the still-buggy Dockerfile without it)"
else
    log_fail "arches.json did not actually widen -- this test's premise (the hazard) does not hold"
fi

echo

# --- 2. non-PR events: gated to exactly the 4 core arches -------------------

echo "=== workflow_dispatch / release: gated to tier==core (4 arches, not 35) ==="

DISPATCH_NAMES=$("${SELECT_MATRIX}" workflow_dispatch "${ARCHES_JSON}" | jq -c '[.[].name] | sort')
assert_eq "workflow_dispatch selects exactly the 4 core arches" "${CORE_NAMES}" "${DISPATCH_NAMES}"

RELEASE_NAMES=$("${SELECT_MATRIX}" release "${ARCHES_JSON}" | jq -c '[.[].name] | sort')
assert_eq "release selects exactly the 4 core arches" "${CORE_NAMES}" "${RELEASE_NAMES}"

DISPATCH_COUNT=$("${SELECT_MATRIX}" workflow_dispatch "${ARCHES_JSON}" | jq 'length')
assert_eq "workflow_dispatch count is 4, not 35" "4" "${DISPATCH_COUNT}"

echo

# --- 3. every selected row is tier==core, and no core arch is missing ------

echo "=== every non-PR-selected row is tier==core (no extended/infeasible leak) ==="

NON_CORE_LEAKED=$("${SELECT_MATRIX}" workflow_dispatch "${ARCHES_JSON}" | jq '[.[] | select(.tier != "core")] | length')
assert_eq "no non-core row leaks through the gate" "0" "${NON_CORE_LEAKED}"

CORE_MISSING=$(jq --argjson selected "$("${SELECT_MATRIX}" workflow_dispatch "${ARCHES_JSON}" | jq -c '[.[].name]')" \
    '[.[] | select(.tier == "core") | select(([.name] - $selected) != [])] | length' "${ARCHES_JSON}")
assert_eq "no core arch is missing from the gated selection" "0" "${CORE_MISSING}"

echo

# --- 4. pull_request: canary-only, independent of container_arch -----------

echo "=== pull_request: keyed strictly on canary==true ==="

PR_NAMES=$("${SELECT_MATRIX}" pull_request "${ARCHES_JSON}" | jq -c '[.[].name] | sort')
CANARY_NAMES=$(jq -c '[.[] | select(.canary == true) | .name] | sort' "${ARCHES_JSON}")
assert_eq "pull_request selects exactly the canary set" "${CANARY_NAMES}" "${PR_NAMES}"
assert_eq "pull_request selects exactly mips_24kc" '["mips_24kc"]' "${PR_NAMES}"

echo

echo "=== A64 over-select regression (round-2 P-SEV2): PR count independent of container_arch ==="

# arches.json now carries FOUR goarch=="arm64" rows (A64 family widened in
# S1b), one of which -- aarch64_cortex-a53 -- still carries
# container_arch=="aarch64", the exact field the old (deleted)
# `.canary == true or .container_arch == "aarch64"` clause matched on. The
# regression this guards: that clause would have pulled all 4 into every PR
# leg. Assert the precondition actually holds (so this is a real regression
# guard, not vacuously true), then assert PR selection is unaffected.
ARM64_COUNT=$(jq '[.[] | select(.goarch == "arm64")] | length' "${ARCHES_JSON}")
assert_eq "precondition: arches.json has 4 arm64 (A64) rows" "4" "${ARM64_COUNT}"

CONTAINER_AARCH64_COUNT=$(jq '[.[] | select(.container_arch == "aarch64")] | length' "${ARCHES_JSON}")
assert_eq "precondition: exactly 1 row still carries container_arch==aarch64 (the deleted OR-clause's old key)" \
    "1" "${CONTAINER_AARCH64_COUNT}"

PR_COUNT=$("${SELECT_MATRIX}" pull_request "${ARCHES_JSON}" | jq 'length')
assert_eq "PR selection count stays 1 (canary-only) despite 4 arm64/A64 rows existing" "1" "${PR_COUNT}"

PR_HAS_AARCH64=$("${SELECT_MATRIX}" pull_request "${ARCHES_JSON}" | jq '[.[] | select(.goarch == "arm64")] | length')
assert_eq "no arm64/A64 row is pulled into the PR leg (canary is mips_24kc, not aarch64)" "0" "${PR_HAS_AARCH64}"

harness_finish "tests/apk/select-matrix.sh"
