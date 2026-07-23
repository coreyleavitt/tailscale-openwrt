#!/bin/sh
# tests/apk/select-matrix.sh
#
# Slice S1b/S5a/S7a test (RFC docs/rfc-apk-arch-coverage.md §5.8
# migration-safety gate + §5.3 round-2 P-SEV2/F-SEV2 PR-canary-key fix +
# the S5a gate-flip + §5.6 CI verification):
# scripts/select-matrix.sh operates over the widened 35-row arches.json
# (S1b), with FOUR independently-gated named outputs (S1.5/S5a/S7a):
#   --ipk-arches (default)   -- pinned to tier=="core" FOREVER (ipk must
#                                never widen, RFC non-goal).
#   --compile-families       -- S5a gate-flip: every FEASIBLE (reason==null)
#                                arch/family, tier=="core"-only filter DROPPED.
#   --publish-arches         -- same S5a gate-flip, flat per-arch shape.
#   --verify-families        -- S7a: one row per BOOTABLE family (a family
#                                with a native_verify:true arch, per
#                                arches.sh --with-ci), event-conditional.
#
# No docker/qemu needed -- pure jq/shell, exercising the real (committed)
# arches.json directly, the same style as tests/apk/arches.sh.
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
#   7. S7a --verify-families: non-PR selects exactly the 10 bootable-family
#      representatives (excluding the 4 S7b-unverified families), each row
#      carrying the fields the qemu-verify/native-install-verify CI job
#      needs; PR selects exactly the canary's family, count-stable
#      regardless of how many arches share a family; order-independence.
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
# S1b), two of which -- aarch64_cortex-a53 (the legacy core pin) and
# aarch64_generic (S7a's true native-match verify pin) -- carry
# container_arch=="aarch64", the exact field the old (deleted)
# `.canary == true or .container_arch == "aarch64"` clause matched on. The
# regression this guards: that clause would have pulled all 4 into every PR
# leg. Assert the precondition actually holds (so this is a real regression
# guard, not vacuously true), then assert PR selection is unaffected.
ARM64_COUNT=$(jq '[.[] | select(.goarch == "arm64")] | length' "${ARCHES_JSON}")
assert_eq "precondition: arches.json has 4 arm64 (A64) rows" "4" "${ARM64_COUNT}"

CONTAINER_AARCH64_COUNT=$(jq '[.[] | select(.container_arch == "aarch64")] | length' "${ARCHES_JSON}")
assert_eq "precondition: 2 rows now carry container_arch==aarch64 (the deleted OR-clause's old key)" \
    "2" "${CONTAINER_AARCH64_COUNT}"

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

echo "=== --compile-families: each family's build tuple matches arches.sh --id-for ==="

for fam in A64 ASOFT M32BE M32LE A6HF A7HF AMD64 LOONG64 M32LEHF M64BE M64LE RV64 X86SOFT X86SSE2; do
    ROW=$(echo "${FAMILIES_JSON}" | jq -c --arg f "${fam}" '.[] | select(.family == $f)')
    GOARCH=$(echo "${ROW}" | jq -r '.goarch')
    GOARM=$(echo "${ROW}" | jq -r '.goarm')
    GOMIPS=$(echo "${ROW}" | jq -r '.gomips')
    GOMIPS64=$(echo "${ROW}" | jq -r '.gomips64')
    GO386=$(echo "${ROW}" | jq -r '.go386')
    DERIVED=$(sh "${REPO_ROOT}/scripts/arches.sh" --id-for "${GOARCH}" "${GOARM}" "${GOMIPS}" "${GOMIPS64}" "${GO386}")
    assert_eq "family ${fam}: its own build tuple re-derives to ${fam} via arches.sh --id-for" \
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

echo

# --- 7. --verify-families (S7a, RFC §5.6): bootable-family reps ------------

echo "=== --verify-families: non-PR selects exactly the 10 bootable-family representatives ==="

VERIFY_JSON=$("${SELECT_MATRIX}" workflow_dispatch --verify-families "${ARCHES_JSON}")
VERIFY_COUNT=$(echo "${VERIFY_JSON}" | jq 'length')
assert_eq "workflow_dispatch --verify-families count is 10 (the RFC §5.6 bootable set, X86SOFT resolved bootable)" \
    "10" "${VERIFY_COUNT}"

EXPECTED_VERIFY_FAMILIES='["A64","A7HF","AMD64","LOONG64","M32BE","M32LE","M64BE","M64LE","X86SOFT","X86SSE2"]'
VERIFY_FAMILY_NAMES=$(echo "${VERIFY_JSON}" | jq -c '[.[].family] | sort')
assert_eq "--verify-families yields exactly the 10 bootable family ids" \
    "${EXPECTED_VERIFY_FAMILIES}" "${VERIFY_FAMILY_NAMES}"

RELEASE_VERIFY_JSON=$("${SELECT_MATRIX}" release --verify-families "${ARCHES_JSON}")
assert_eq "release --verify-families matches workflow_dispatch --verify-families" \
    "$(echo "${VERIFY_JSON}" | jq -S .)" "$(echo "${RELEASE_VERIFY_JSON}" | jq -S .)"

echo

echo "=== --verify-families: the 4 S7b-unverified families never appear ==="

for unverified_family in A6HF ASOFT M32LEHF RV64; do
    PRESENT=$(echo "${VERIFY_JSON}" | jq --arg f "${unverified_family}" '[.[] | select(.family == $f)] | length')
    assert_eq "unverified family ${unverified_family} is absent from --verify-families" "0" "${PRESENT}"
done

echo

echo "=== --verify-families: every row carries the fields the CI verify job needs ==="

MISSING_VERIFY_FIELDS=$(echo "${VERIFY_JSON}" | jq \
    '[.[] | select(.verify == null or .verify == ""
                    or .rootfs_url == null or .rootfs_url == ""
                    or .rootfs_sha256 == null or .rootfs_sha256 == ""
                    or .container_arch == null or .container_arch == ""
                    or .goarch == null or .goarch == "")] | length')
assert_eq "every --verify-families row carries verify/rootfs_url/rootfs_sha256/container_arch/goarch" \
    "0" "${MISSING_VERIFY_FIELDS}"

echo

echo "=== --verify-families: A64/A7HF resolve to the true native-match arch (D2 regression guard) ==="

A64_VERIFY_NAME=$(echo "${VERIFY_JSON}" | jq -r '.[] | select(.family == "A64") | .verify')
assert_eq "verify_families' A64 representative is aarch64_generic, not aarch64_cortex-a53" \
    "aarch64_generic" "${A64_VERIFY_NAME}"

A7HF_VERIFY_NAME=$(echo "${VERIFY_JSON}" | jq -r '.[] | select(.family == "A7HF") | .verify')
assert_eq "verify_families' A7HF representative is arm_cortex-a15_neon-vfpv4, not arm_cortex-a7" \
    "arm_cortex-a15_neon-vfpv4" "${A7HF_VERIFY_NAME}"

echo

echo "=== --verify-families: pull_request selects exactly the canary's family, count-stable ==="

PR_VERIFY_JSON=$("${SELECT_MATRIX}" pull_request --verify-families "${ARCHES_JSON}")
assert_eq "pull_request --verify-families count is 1" "1" "$(echo "${PR_VERIFY_JSON}" | jq 'length')"
assert_eq "pull_request --verify-families is M32BE (mips_24kc's family)" '["M32BE"]' \
    "$(echo "${PR_VERIFY_JSON}" | jq -c '[.[].family]')"
assert_eq "pull_request --verify-families verify arch is exactly the canary arch" '"mips_24kc"' \
    "$(echo "${PR_VERIFY_JSON}" | jq -c '.[0].verify')"

# Same over-select regression as section 4 above, applied to verify_families:
# PR count must stay 1 even though A64 has 4 gated arm64 rows and one of them
# (aarch64_cortex-a53) still carries container_arch=="aarch64".
PR_VERIFY_HAS_A64=$(echo "${PR_VERIFY_JSON}" | jq '[.[] | select(.family == "A64")] | length')
assert_eq "no A64 row is pulled into the --verify-families PR leg" "0" "${PR_VERIFY_HAS_A64}"

echo

echo "=== --verify-families: order-independence (row-shuffled arches.json yields the same set) ==="

SHUFFLED_JSON3=$(mktemp)
jq '[.[3], .[1], .[0], .[2]] + .[4:]' "${ARCHES_JSON}" > "${SHUFFLED_JSON3}"
SHUFFLED_VERIFY=$("${SELECT_MATRIX}" workflow_dispatch --verify-families "${SHUFFLED_JSON3}" | jq -S 'sort_by(.family)')
ORIGINAL_VERIFY=$(echo "${VERIFY_JSON}" | jq -S 'sort_by(.family)')
assert_eq "shuffling arches.json's row order does not change the --verify-families view" \
    "${ORIGINAL_VERIFY}" "${SHUFFLED_VERIFY}"
rm -f "${SHUFFLED_JSON3}"

echo

echo "=== --verify-families: hard-fails on a canary arch whose family is not bootable (RFC §5.2 canary subseteq verify) ==="

# Flip canary onto arm_cortex-a7 (ASOFT -- genuinely unbootable, no
# native_verify:true row anywhere in its family) instead of mips_24kc
# (M32BE -- bootable). This must hard-fail loudly, not silently shrink the
# PR matrix to zero rows.
CANARY_MISMATCH_JSON=$(mktemp)
jq '(.[] | select(.name == "mips_24kc") | .canary) |= false
    | (.[] | select(.name == "arm_cortex-a7") | .canary) |= true' \
    "${ARCHES_JSON}" > "${CANARY_MISMATCH_JSON}"

set +e
"${SELECT_MATRIX}" pull_request --verify-families "${CANARY_MISMATCH_JSON}" >"${CANARY_MISMATCH_JSON}.out" 2>&1
CANARY_MISMATCH_RC=$?
set -e

if [ "${CANARY_MISMATCH_RC}" -ne 0 ]; then
    log_info "OK: --verify-families hard-fails when the canary arch's family has no native_verify:true row"
else
    log_fail "--verify-families should hard-fail on a canary arch whose family is unbootable:
$(cat "${CANARY_MISMATCH_JSON}.out")"
fi
rm -f "${CANARY_MISMATCH_JSON}" "${CANARY_MISMATCH_JSON}.out"

# Regression (live 30-arch run 29975876028 failed here): every select-matrix
# output is consumed by the workflow via `echo "key=${value}" >>
# "$GITHUB_OUTPUT"`, which REQUIRES a single-line value -- a multi-line
# (pretty-printed) JSON blob makes GitHub Actions abort the "Select build
# matrix" step with `Invalid format '  {'` and cascades every build/publish
# job to skipped. The M5 refactor regressed --compile-families to pretty JSON
# (arches.sh cmd_compile_families used `jq -s` not `jq -cs`); a jq -S
# byte-identity check masked it because it pretty-prints BOTH sides. Assert
# every mode/event the pipeline uses emits exactly ONE line (no embedded
# newline).
echo "=== every select-matrix output is single-line (GITHUB_OUTPUT-safe) ==="
for _ev in workflow_dispatch release; do
    for _mode in --ipk-arches --compile-families --publish-arches --verify-families; do
        _out=$("${SELECT_MATRIX}" "${_ev}" "${_mode}" "${ARCHES_JSON}")
        _nl=$(printf '%s' "${_out}" | wc -l | tr -d ' ')
        assert_eq "${_ev} ${_mode} output is single-line (GITHUB_OUTPUT-safe)" "0" "${_nl}"
    done
done

harness_finish "tests/apk/select-matrix.sh"
