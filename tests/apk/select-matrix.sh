#!/bin/sh
# tests/apk/select-matrix.sh
#
# Slice S1b/S5a test (RFC docs/rfc-apk-arch-coverage.md §5.8 migration-safety
# gate + §5.3 round-2 P-SEV2/F-SEV2 PR-canary-key fix + the S5a gate-flip):
# scripts/select-matrix.sh operates over the widened 35-row arches.json
# (S1b), with THREE independently-gated named outputs (S1.5/S5a):
#   --ipk-arches (default)   -- pinned to tier=="core" FOREVER (ipk must
#                                never widen, RFC non-goal).
#   --compile-families       -- S5a gate-flip: every FEASIBLE (reason==null)
#                                arch/family, tier=="core"-only filter DROPPED.
#   --publish-arches         -- same S5a gate-flip, flat per-arch shape.
#
# No docker/qemu needed -- pure jq/shell, exercising the real (committed)
# arches.json directly, the same style as tests/apk/families.sh.
#
# Covers:
#   1. THE HAZARD, proven directly: naively dumping the widened arches.json
#      (i.e. `jq '.'`, what select-matrix.sh did before S1b's gate) yields
#      35 rows -- the exact bug the tier=="core" filter exists to prevent.
#   2. --ipk-arches: workflow_dispatch and release (any non-pull_request
#      event) both select EXACTLY the 4 historical `tier=="core"` arches --
#      not the 35 the raw table now has, and NEVER the widened 30 either
#      (ipk must not widen, independent of the compile_families/
#      publish_arches gate-flip below).
#   3. pull_request selects EXACTLY the canary set (mips_24kc), keyed
#      strictly on `canary == true`, IDENTICALLY across all three modes.
#   4. The A64 over-select regression (round-2 P-SEV2): PR selection count
#      does NOT grow now that arches.json carries four `goarch=="arm64"`
#      rows (one of which -- aarch64_cortex-a53 -- still carries
#      `container_arch == "aarch64"`, the exact field the old, deleted
#      `or .container_arch == "aarch64"` clause keyed on). PR selection is
#      asserted independent of container_arch entirely.
#   5. --ipk-arches: every row returned for a non-PR event has
#      `tier == "core"` (no extended/infeasible row ever leaks through the
#      gate), and the reverse: no `tier=="core"` arch is ever missing.
#   6. THE GATE FLIP (S5a): --publish-arches/--compile-families for a non-PR
#      event select all 30 FEASIBLE arches / all 14 families (core-only
#      filter dropped), never an infeasible (reason!=null) row, and never
#      fewer than the full feasible set.
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

# --- 2. non-PR events: --ipk-arches gated to exactly the 4 core arches ------

echo "=== --ipk-arches: workflow_dispatch / release gated to tier==core (4 arches, not 35) ==="

DISPATCH_NAMES=$("${SELECT_MATRIX}" workflow_dispatch --ipk-arches "${ARCHES_JSON}" | jq -c '[.[].name] | sort')
assert_eq "workflow_dispatch --ipk-arches selects exactly the 4 core arches" "${CORE_NAMES}" "${DISPATCH_NAMES}"

RELEASE_NAMES=$("${SELECT_MATRIX}" release --ipk-arches "${ARCHES_JSON}" | jq -c '[.[].name] | sort')
assert_eq "release --ipk-arches selects exactly the 4 core arches" "${CORE_NAMES}" "${RELEASE_NAMES}"

DISPATCH_COUNT=$("${SELECT_MATRIX}" workflow_dispatch --ipk-arches "${ARCHES_JSON}" | jq 'length')
assert_eq "workflow_dispatch --ipk-arches count is 4, not 35" "4" "${DISPATCH_COUNT}"

# No-flag call (backward-compatible default -- several other test files
# invoke select-matrix.sh with no mode flag at all) must be BYTE-IDENTICAL to
# the explicit --ipk-arches call above.
DEFAULT_NAMES=$("${SELECT_MATRIX}" workflow_dispatch "${ARCHES_JSON}" | jq -c '[.[].name] | sort')
assert_eq "no-flag default == explicit --ipk-arches (backward compat for existing call sites)" \
    "${DISPATCH_NAMES}" "${DEFAULT_NAMES}"

echo

# --- 3. every --ipk-arches row is tier==core, and no core arch is missing ---

echo "=== --ipk-arches: every non-PR-selected row is tier==core (no extended/infeasible leak) ==="

NON_CORE_LEAKED=$("${SELECT_MATRIX}" workflow_dispatch --ipk-arches "${ARCHES_JSON}" | jq '[.[] | select(.tier != "core")] | length')
assert_eq "no non-core row leaks through the --ipk-arches gate" "0" "${NON_CORE_LEAKED}"

CORE_MISSING=$(jq --argjson selected "$("${SELECT_MATRIX}" workflow_dispatch --ipk-arches "${ARCHES_JSON}" | jq -c '[.[].name]')" \
    '[.[] | select(.tier == "core") | select(([.name] - $selected) != [])] | length' "${ARCHES_JSON}")
assert_eq "no core arch is missing from the --ipk-arches gated selection" "0" "${CORE_MISSING}"

echo

# --- 4. pull_request: canary-only, independent of container_arch, IDENTICAL
#        across all three modes --------------------------------------------

echo "=== pull_request: keyed strictly on canary==true (identical across all 3 modes) ==="

CANARY_NAMES=$(jq -c '[.[] | select(.canary == true) | .name] | sort' "${ARCHES_JSON}")

for flag in --ipk-arches --publish-arches; do
    PR_NAMES=$("${SELECT_MATRIX}" pull_request "${flag}" "${ARCHES_JSON}" | jq -c '[.[].name] | sort')
    assert_eq "pull_request ${flag} selects exactly the canary set" "${CANARY_NAMES}" "${PR_NAMES}"
    assert_eq "pull_request ${flag} selects exactly mips_24kc" '["mips_24kc"]' "${PR_NAMES}"
done

PR_NAMES_NOFLAG=$("${SELECT_MATRIX}" pull_request "${ARCHES_JSON}" | jq -c '[.[].name] | sort')
assert_eq "pull_request no-flag (default) selects exactly the canary set" "${CANARY_NAMES}" "${PR_NAMES_NOFLAG}"

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

PR_COUNT=$("${SELECT_MATRIX}" pull_request --publish-arches "${ARCHES_JSON}" | jq 'length')
assert_eq "PR selection count stays 1 (canary-only) despite 4 arm64/A64 rows existing" "1" "${PR_COUNT}"

PR_HAS_AARCH64=$("${SELECT_MATRIX}" pull_request --publish-arches "${ARCHES_JSON}" | jq '[.[] | select(.goarch == "arm64")] | length')
assert_eq "no arm64/A64 row is pulled into the PR leg (canary is mips_24kc, not aarch64)" "0" "${PR_HAS_AARCH64}"

echo

# --- 5. --compile-families (S5a GATE FLIP, RFC §5.3/§5.8): one row per -----
# family, gated to every FEASIBLE arch (tier=="core"-only filter DROPPED --
# this is the single behavioral change that makes the extended arches go
# live), carrying the build tuple + that family's gated arch list. This is
# what build-apk's compile-once-per-family / package-per-arch-in-job
# restructure matrixes over -- NOT the flat arches list build-ipk still uses.

echo "=== --compile-families GATE FLIP: non-PR gives all 14 families (core-only filter dropped) ==="

FAMILIES_JSON=$("${SELECT_MATRIX}" workflow_dispatch --compile-families "${ARCHES_JSON}")
FAMILY_COUNT=$(echo "${FAMILIES_JSON}" | jq 'length')
assert_eq "workflow_dispatch --compile-families count is 14, not 4 (gate-flip widened)" "14" "${FAMILY_COUNT}"

EXPECTED_FAMILIES='["A64","A6HF","A7HF","AMD64","ASOFT","LOONG64","M32BE","M32LE","M32LEHF","M64BE","M64LE","RV64","X86SOFT","X86SSE2"]'
FAMILY_NAMES=$(echo "${FAMILIES_JSON}" | jq -c '[.[].family] | sort')
assert_eq "workflow_dispatch --compile-families yields exactly the 14 known family ids" \
    "${EXPECTED_FAMILIES}" "${FAMILY_NAMES}"

RELEASE_FAMILIES_JSON=$("${SELECT_MATRIX}" release --compile-families "${ARCHES_JSON}")
assert_eq "release --compile-families matches workflow_dispatch --compile-families" \
    "$(echo "${FAMILIES_JSON}" | jq -S .)" "$(echo "${RELEASE_FAMILIES_JSON}" | jq -S .)"

echo

echo "=== --compile-families: no infeasible arch ever leaks into any family's arch list ==="

INFEASIBLE_NAMES=$(jq -c '[.[] | select(.tier == "infeasible") | .name]' "${ARCHES_JSON}")
ALL_GATED_ARCHES=$(echo "${FAMILIES_JSON}" | jq -c '[.[].arches[]] | sort')
LEAKED_INFEASIBLE=$(jq -n --argjson all "${ALL_GATED_ARCHES}" --argjson bad "${INFEASIBLE_NAMES}" \
    '[$all[] as $a | $bad[] | select(. == $a)] | length')
assert_eq "no tier==infeasible arch appears in any --compile-families arch list" "0" "${LEAKED_INFEASIBLE}"

TOTAL_GATED_ARCH_COUNT=$(echo "${ALL_GATED_ARCHES}" | jq 'length')
assert_eq "--compile-families' arch lists sum to exactly 30 (all feasible arches, no fewer)" "30" "${TOTAL_GATED_ARCH_COUNT}"

echo

echo "=== --compile-families: each family's build tuple matches families.sh --id-for ==="

for fam in A64 ASOFT M32BE M32LE A6HF A7HF AMD64 LOONG64 M32LEHF M64BE M64LE RV64 X86SOFT X86SSE2; do
    ROW=$(echo "${FAMILIES_JSON}" | jq -c --arg f "${fam}" '.[] | select(.family == $f)')
    GOARCH=$(echo "${ROW}" | jq -r '.goarch')
    GOARM=$(echo "${ROW}" | jq -r '.goarm')
    GOMIPS=$(echo "${ROW}" | jq -r '.gomips')
    GOMIPS64=$(echo "${ROW}" | jq -r '.gomips64')
    GO386=$(echo "${ROW}" | jq -r '.go386')
    DERIVED=$(sh "${REPO_ROOT}/scripts/families.sh" --id-for "${GOARCH}" "${GOARM}" "${GOMIPS}" "${GOMIPS64}" "${GO386}")
    assert_eq "family ${fam}: its own build tuple re-derives to ${fam} via families.sh --id-for" \
        "${fam}" "${DERIVED}"
done

echo

echo "=== --compile-families: the historical core arch is still present in its (now wider) family ==="

assert_eq "families view: A64's arch list still includes aarch64_cortex-a53" "true" \
    "$(echo "${FAMILIES_JSON}" | jq '.[] | select(.family == "A64") | .arches | index("aarch64_cortex-a53") != null')"
assert_eq "families view: ASOFT's arch list still includes arm_cortex-a7" "true" \
    "$(echo "${FAMILIES_JSON}" | jq '.[] | select(.family == "ASOFT") | .arches | index("arm_cortex-a7") != null')"
assert_eq "families view: M32BE's arch list still includes mips_24kc" "true" \
    "$(echo "${FAMILIES_JSON}" | jq '.[] | select(.family == "M32BE") | .arches | index("mips_24kc") != null')"
assert_eq "families view: M32LE's arch list still includes mipsel_24kc" "true" \
    "$(echo "${FAMILIES_JSON}" | jq '.[] | select(.family == "M32LE") | .arches | index("mipsel_24kc") != null')"

echo

echo "=== --compile-families: pull_request STILL gives exactly the canary's family (M32BE) -- unaffected by the gate flip ==="

PR_FAMILIES_JSON=$("${SELECT_MATRIX}" pull_request --compile-families "${ARCHES_JSON}")
assert_eq "pull_request --compile-families count is 1" "1" "$(echo "${PR_FAMILIES_JSON}" | jq 'length')"
assert_eq "pull_request --compile-families is M32BE (mips_24kc's family)" '["M32BE"]' \
    "$(echo "${PR_FAMILIES_JSON}" | jq -c '[.[].family]')"
assert_eq "pull_request --compile-families M32BE arch list is exactly the canary arch" '["mips_24kc"]' \
    "$(echo "${PR_FAMILIES_JSON}" | jq -c '.[0].arches')"

echo

# --- 6. --publish-arches (S5a GATE FLIP): flat widened arch list -----------

echo "=== --publish-arches GATE FLIP: non-PR gives all 30 feasible arches (core-only filter dropped) ==="

PUBLISH_JSON=$("${SELECT_MATRIX}" workflow_dispatch --publish-arches "${ARCHES_JSON}")
PUBLISH_COUNT=$(echo "${PUBLISH_JSON}" | jq 'length')
assert_eq "workflow_dispatch --publish-arches count is 30, not 4" "30" "${PUBLISH_COUNT}"

PUBLISH_INFEASIBLE_LEAK=$(echo "${PUBLISH_JSON}" | jq '[.[] | select(.reason != null)] | length')
assert_eq "no reason!=null (infeasible) arch ever appears in --publish-arches" "0" "${PUBLISH_INFEASIBLE_LEAK}"

PUBLISH_MISSING=$(jq --argjson selected "$(echo "${PUBLISH_JSON}" | jq -c '[.[].name]')" \
    '[.[] | select(.reason == null) | select(([.name] - $selected) != [])] | length' "${ARCHES_JSON}")
assert_eq "no feasible arch is missing from --publish-arches" "0" "${PUBLISH_MISSING}"

# tier is carried through (RFC §5.4's core/extended atomicity split, S5b,
# reads this field -- not implemented by select-matrix.sh itself).
PUBLISH_MISSING_TIER=$(echo "${PUBLISH_JSON}" | jq '[.[] | select(.tier == null or .tier == "")] | length')
assert_eq "every --publish-arches row still carries its tier field" "0" "${PUBLISH_MISSING_TIER}"

RELEASE_PUBLISH_JSON=$("${SELECT_MATRIX}" release --publish-arches "${ARCHES_JSON}")
assert_eq "release --publish-arches matches workflow_dispatch --publish-arches" \
    "$(echo "${PUBLISH_JSON}" | jq -S '[.[].name] | sort')" "$(echo "${RELEASE_PUBLISH_JSON}" | jq -S '[.[].name] | sort')"

echo

echo "=== --publish-arches: pull_request STILL gives exactly the canary arch -- unaffected by the gate flip ==="

PR_PUBLISH_JSON=$("${SELECT_MATRIX}" pull_request --publish-arches "${ARCHES_JSON}")
assert_eq "pull_request --publish-arches count is 1" "1" "$(echo "${PR_PUBLISH_JSON}" | jq 'length')"
assert_eq "pull_request --publish-arches is exactly mips_24kc" '["mips_24kc"]' \
    "$(echo "${PR_PUBLISH_JSON}" | jq -c '[.[].name]')"

echo

echo "=== --compile-families: order-independence (row-shuffled arches.json yields the same families view) ==="

SHUFFLED_JSON=$(mktemp)
jq '[.[3], .[1], .[0], .[2]] + .[4:]' "${ARCHES_JSON}" > "${SHUFFLED_JSON}"
SHUFFLED_FAMILIES=$("${SELECT_MATRIX}" workflow_dispatch --compile-families "${SHUFFLED_JSON}" | jq -S .)
ORIGINAL_FAMILIES=$(echo "${FAMILIES_JSON}" | jq -S .)
assert_eq "shuffling arches.json's row order does not change the --compile-families view" \
    "${ORIGINAL_FAMILIES}" "${SHUFFLED_FAMILIES}"
rm -f "${SHUFFLED_JSON}"

echo

echo "=== --publish-arches: order-independence (row-shuffled arches.json yields the same set) ==="

SHUFFLED_JSON2=$(mktemp)
jq '[.[3], .[1], .[0], .[2]] + .[4:]' "${ARCHES_JSON}" > "${SHUFFLED_JSON2}"
SHUFFLED_PUBLISH=$("${SELECT_MATRIX}" workflow_dispatch --publish-arches "${SHUFFLED_JSON2}" | jq -S '[.[].name] | sort')
ORIGINAL_PUBLISH=$(echo "${PUBLISH_JSON}" | jq -S '[.[].name] | sort')
assert_eq "shuffling arches.json's row order does not change the --publish-arches name set" \
    "${ORIGINAL_PUBLISH}" "${SHUFFLED_PUBLISH}"
rm -f "${SHUFFLED_JSON2}"

harness_finish "tests/apk/select-matrix.sh"
