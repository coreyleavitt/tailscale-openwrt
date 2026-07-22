#!/bin/sh
# tests/apk/arches.sh
#
# Slices S1a+S1b test (RFC docs/rfc-apk-arch-coverage.md §5.2 + Slices):
# the v2 `arches.json` fields (goarm/gomips/gomips64/go386/float/reason/tier),
# the S1b widen to the full 35-row Appendix table (30 feasible + 5
# infeasible, gated inert per §5.8), plus scripts/arches.sh -- the pure,
# content-derived deriver that maps a build tuple to one of the 14 mnemonic
# family ids (§4's table). No docker/qemu needed: this is a jq/shell unit
# test in the tests/apk/lib.sh harness style (see host-apk.sh/rootfs.sh).
#
# Covers:
#   1. arches.json v2 field values on the 4 original rows match the RFC
#      Appendix exactly (esp. arm_cortex-a7 float=soft, the already-shipped
#      r2 fix).
#   2. `--id-for` returns the correct mnemonic for each of the 4 present
#      tuples, and hard-fails (non-zero exit, stderr message, no generic
#      fallback id) on a made-up/unmapped tuple.
#   3. `--validate` passes on the real (now 35-row) arches.json, and fails on
#      two distinct fixtured bad rows: a typo'd enum value, and a tuple that
#      doesn't map to any known family.
#   4. id-stability: shuffling the 4-row fixture's row order does not change
#      any family id, and adding a second arch to an existing family (its
#      own fixture) does not change any OTHER family's id.
#   5. `--with-ci` emits exactly one `verify` arch per family, and that arch
#      is bootable (carries a real rootfs pin) -- exercised against the
#      frozen 4-row fixture, not the live table (see FAMILIES_4ROW_FIXTURE's
#      comment below for why).
#   6. S1b widen: arches.json has exactly 35 rows (30 feasible/5 infeasible,
#      4 core/26 extended), every row is consistently classified (blank
#      tuple + reason iff infeasible), `--validate` reports exactly 14
#      families, and each of the 14 mnemonics is actually produced by some
#      feasible row's tuple.
#   7. S7a: `--with-ci` is native_verify:true-flag-driven, not "first row with a
#      rootfs pin" -- a family with NO native_verify:true row is EXCLUDED from the
#      view (not hard-failed: that's the S7b unverified tier), a family
#      with a native_verify:true row gets exactly that row back (even when a
#      SIBLING row in the same family also carries a rootfs pin -- the
#      exact aarch64_cortex-a53-vs-aarch64_generic case S7a found), and
#      `--validate` catches two authoring mistakes: a native_verify:true row
#      lacking a real rootfs pin, and two native_verify:true rows in one family.
#      Exercised against the REAL (now S7a-pinned) arches.json: exactly 10
#      bootable families (A64/A7HF/M32BE/M32LE/M64BE/M64LE/X86SSE2/
#      X86SOFT/AMD64/LOONG64), the other 4 (A6HF/ASOFT/M32LEHF/RV64)
#      excluded.
#   8. M8 (code-review finding): the row field is `native_verify`, never the
#      old bare `verify` (which used to collide in name with --with-ci's own
#      OUTPUT key `verify`, an arch-name string -- that OUTPUT key is
#      asserted UNCHANGED). It is explicitly LEGAL for a row to carry a real
#      rootfs pin while `native_verify: false` (the aarch64_cortex-a53/
#      arm_cortex-a7 core-ARM case) -- `--validate` accepts this on the real
#      table, not just rejects the two authored-mistake shapes section 7
#      already covers.
#   9. R1 (round-2 code-review finding): `--validate` ITSELF (not just this
#      test's own jq predicate) rejects a row whose `tier`/`reason` fields
#      disagree on feasibility -- a feasible tier (extended) with a
#      non-null reason, and the converse (infeasible tier with a null
#      reason) -- naming the offending row in both directions.
#  10. R2a (round-2 code-review finding, companion to
#      gen-install-arch-block.sh's row-parsing fix in
#      tests/apk/install-arch-block.sh): `--validate` rejects a `.reason`
#      containing an embedded newline, including an injection-shaped
#      payload that would otherwise splice raw case-arm syntax into the
#      GENERATED install.sh block.
#
# Usage: sh tests/apk/arches.sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
ARCHES_SH="${REPO_ROOT}/scripts/arches.sh"
ARCHES_JSON="${REPO_ROOT}/arches.json"

# S1b widened the real arches.json to the full 35-row Appendix table; S7a
# then pinned rootfs images + set `native_verify: true` (M8: renamed from
# `verify` -- see scripts/arches.sh's header comment) for the 10
# CI-bootable families (§5.6) -- 4 families (A6HF/ASOFT/M32LEHF/RV64)
# remain genuinely unbootable (no generic rootfs exists upstream) and stay
# `native_verify: false` on every row, so `--with-ci` excludes them (the
# S7b unverified tier). The
# id-stability / one-verify-per-family sections below are unit tests of
# `--with-ci`'s OWN properties (order-independence, native_verify:true-flag
# selection over a fragile "first with a rootfs pin" inference) -- they
# exercise a frozen 4-row fixture (one arch per family, every family
# native_verify:true) so they stay independent of how many families the live
# table happens to have pinned at any given time.
FAMILIES_4ROW_FIXTURE="${SCRIPT_DIR}/fixtures/families-4row.json"

# shellcheck source=tests/apk/lib.sh
. "${SCRIPT_DIR}/lib.sh"

require_cmd jq

if [ ! -f "${ARCHES_SH}" ]; then
    log_fail "scripts/arches.sh not found at ${ARCHES_SH}"
    harness_finish "tests/apk/arches.sh"
    exit "${FAIL}"
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "${WORKDIR}"' EXIT

# --- 1. arches.json v2 field values (RFC Appendix, exact) ------------------

echo "=== arches.json: v2 fields on the 4 existing rows ==="

row() {
    # row <arch-name> <field>
    jq -r --arg n "$1" --arg f "$2" '.[] | select(.name == $n) | .[$f]' "${ARCHES_JSON}"
}

assert_eq "aarch64_cortex-a53 goarch"    "arm64"  "$(row aarch64_cortex-a53 goarch)"
assert_eq "aarch64_cortex-a53 goarm"     ""       "$(row aarch64_cortex-a53 goarm)"
assert_eq "aarch64_cortex-a53 gomips"    ""       "$(row aarch64_cortex-a53 gomips)"
assert_eq "aarch64_cortex-a53 gomips64"  ""       "$(row aarch64_cortex-a53 gomips64)"
assert_eq "aarch64_cortex-a53 go386"     ""       "$(row aarch64_cortex-a53 go386)"
assert_eq "aarch64_cortex-a53 float"     "hard"   "$(row aarch64_cortex-a53 float)"
assert_eq "aarch64_cortex-a53 reason"    "null"   "$(row aarch64_cortex-a53 reason)"
assert_eq "aarch64_cortex-a53 tier"      "core"   "$(row aarch64_cortex-a53 tier)"
assert_eq "aarch64_cortex-a53 canary (unchanged)" "false" "$(row aarch64_cortex-a53 canary)"

assert_eq "arm_cortex-a7 goarch"    "arm"    "$(row arm_cortex-a7 goarch)"
assert_eq "arm_cortex-a7 goarm (unchanged, already r2-fixed)" "5" "$(row arm_cortex-a7 goarm)"
assert_eq "arm_cortex-a7 gomips64"  ""       "$(row arm_cortex-a7 gomips64)"
assert_eq "arm_cortex-a7 go386"     ""       "$(row arm_cortex-a7 go386)"
assert_eq "arm_cortex-a7 float (bare cortex-a7 is softfloat, §4/§9)" "soft" "$(row arm_cortex-a7 float)"
assert_eq "arm_cortex-a7 reason"    "null"   "$(row arm_cortex-a7 reason)"
assert_eq "arm_cortex-a7 tier"      "core"   "$(row arm_cortex-a7 tier)"
assert_eq "arm_cortex-a7 canary (unchanged)" "false" "$(row arm_cortex-a7 canary)"

assert_eq "mips_24kc goarch"    "mips"       "$(row mips_24kc goarch)"
assert_eq "mips_24kc gomips (unchanged)" "softfloat" "$(row mips_24kc gomips)"
assert_eq "mips_24kc gomips64"  ""           "$(row mips_24kc gomips64)"
assert_eq "mips_24kc go386"     ""           "$(row mips_24kc go386)"
assert_eq "mips_24kc float"     "soft"       "$(row mips_24kc float)"
assert_eq "mips_24kc reason"    "null"       "$(row mips_24kc reason)"
assert_eq "mips_24kc tier"      "core"       "$(row mips_24kc tier)"
assert_eq "mips_24kc canary (unchanged, the PR canary arch)" "true" "$(row mips_24kc canary)"

assert_eq "mipsel_24kc goarch"   "mipsle"     "$(row mipsel_24kc goarch)"
assert_eq "mipsel_24kc gomips (unchanged)" "softfloat" "$(row mipsel_24kc gomips)"
assert_eq "mipsel_24kc gomips64" ""           "$(row mipsel_24kc gomips64)"
assert_eq "mipsel_24kc go386"    ""           "$(row mipsel_24kc go386)"
assert_eq "mipsel_24kc float"    "soft"       "$(row mipsel_24kc float)"
assert_eq "mipsel_24kc reason"   "null"       "$(row mipsel_24kc reason)"
assert_eq "mipsel_24kc tier"     "core"       "$(row mipsel_24kc tier)"
assert_eq "mipsel_24kc canary (unchanged)" "false" "$(row mipsel_24kc canary)"

echo

# --- 2. --id-for: the 4 present tuples + hard-fail on an unmapped tuple ----

echo "=== arches.sh --id-for: 4 present tuples ==="

assert_eq "id-for aarch64_cortex-a53 tuple -> A64" "A64" \
    "$("${ARCHES_SH}" --id-for arm64 "" "" "" "")"
assert_eq "id-for arm_cortex-a7 tuple -> ASOFT" "ASOFT" \
    "$("${ARCHES_SH}" --id-for arm 5 "" "" "")"
assert_eq "id-for mips_24kc tuple -> M32BE" "M32BE" \
    "$("${ARCHES_SH}" --id-for mips "" softfloat "" "")"
assert_eq "id-for mipsel_24kc tuple -> M32LE" "M32LE" \
    "$("${ARCHES_SH}" --id-for mipsle "" softfloat "" "")"

echo
echo "=== arches.sh --id-for: hard-fail on an unmapped tuple ==="

set +e
BOGUS_OUT=$("${ARCHES_SH}" --id-for sparc64 "" "" "" "" 2>"${WORKDIR}/bogus.err")
BOGUS_RC=$?
set -e
BOGUS_ERR=$(cat "${WORKDIR}/bogus.err")

if [ "${BOGUS_RC}" -eq 0 ]; then
    log_fail "--id-for sparc64 ... should hard-fail (exit 0, stdout: '${BOGUS_OUT}')"
else
    log_info "OK: --id-for sparc64 ... exits non-zero (${BOGUS_RC})"
fi
assert_eq "--id-for on unmapped tuple prints NOTHING to stdout (no generic id)" "" "${BOGUS_OUT}"
if [ -n "${BOGUS_ERR}" ]; then
    log_info "OK: --id-for on unmapped tuple writes a stderr message (${BOGUS_ERR})"
else
    log_fail "--id-for on unmapped tuple produced no stderr message"
fi

echo

# --- 3. --validate: real arches.json passes; fixtured bad rows fail --------

echo "=== arches.sh --validate: real arches.json passes ==="

if "${ARCHES_SH}" --validate "${ARCHES_JSON}" >"${WORKDIR}/validate-good.out" 2>&1; then
    log_info "OK: --validate passes on the real arches.json"
else
    log_fail "--validate failed on the real arches.json:
$(cat "${WORKDIR}/validate-good.out")"
fi

echo
echo "=== arches.sh --validate: fixtured typo'd enum fails ==="

jq '(.[] | select(.name == "mips_24kc") | .float) |= "sof"' "${ARCHES_JSON}" \
    > "${WORKDIR}/bad-enum.json"

set +e
"${ARCHES_SH}" --validate "${WORKDIR}/bad-enum.json" >"${WORKDIR}/bad-enum.out" 2>&1
BAD_ENUM_RC=$?
set -e

if [ "${BAD_ENUM_RC}" -ne 0 ]; then
    log_info "OK: --validate rejects a typo'd float enum ('sof')"
else
    log_fail "--validate accepted a typo'd float enum ('sof'):
$(cat "${WORKDIR}/bad-enum.out")"
fi

echo
echo "=== arches.sh --validate: fixtured unmapped tuple fails ==="

jq '(.[] | select(.name == "mips_24kc") | .goarm) |= "3"' "${ARCHES_JSON}" \
    > "${WORKDIR}/bad-tuple.json"

set +e
"${ARCHES_SH}" --validate "${WORKDIR}/bad-tuple.json" >"${WORKDIR}/bad-tuple.out" 2>&1
BAD_TUPLE_RC=$?
set -e

if [ "${BAD_TUPLE_RC}" -ne 0 ]; then
    log_info "OK: --validate rejects a row whose tuple maps to no known family"
else
    log_fail "--validate accepted an unmapped build tuple:
$(cat "${WORKDIR}/bad-tuple.out")"
fi

echo

# --- 4. id-stability -------------------------------------------------------

echo "=== id-stability: row-order shuffle does not change any family id ==="

jq '[.[3], .[1], .[2], .[0]]' "${FAMILIES_4ROW_FIXTURE}" > "${WORKDIR}/shuffled.json"

ORIG_FAMILIES=$("${ARCHES_SH}" --with-ci "${FAMILIES_4ROW_FIXTURE}" | jq -S 'sort_by(.family)')
SHUFFLED_FAMILIES=$("${ARCHES_SH}" --with-ci "${WORKDIR}/shuffled.json" | jq -S 'sort_by(.family)')

assert_eq "with-ci output is identical (as a set) regardless of row order" \
    "${ORIG_FAMILIES}" "${SHUFFLED_FAMILIES}"

echo
echo "=== id-stability: adding a 2nd arch to an existing family leaves other families' ids untouched ==="

# arm_cortex-a9 (bare) shares arm_cortex-a7's exact build tuple (arm/GOARM=5,
# softfloat) -- same family, ASOFT (§4 Appendix) -- so this fixture adds a
# genuine second member to an existing family, not a new one. native_verify:false --
# arm_cortex-a7 (already native_verify:true in the fixture) stays ASOFT's ONE
# representative; a second native_verify:true row in the same family is a schema
# violation (--with-ci hard-fails on it), not something this fixture means to
# exercise.
jq '. + [{
        "name": "arm_cortex-a9",
        "goarch": "arm", "goarm": "5", "gomips": "", "gomips64": "", "go386": "",
        "endian": "little", "float": "soft", "reason": null,
        "rootfs_target": "armsr/armv7",
        "canary": false,
        "rootfs_url": "https://downloads.openwrt.org/releases/25.12.0/targets/armsr/armv7/openwrt-25.12.0-armsr-armv7-rootfs.tar.gz",
        "rootfs_sha256": "97bd0ac74bf7e9473162449932f7e336e509da467e5ce45d960716934f77e5ce",
        "container_arch": "armv7",
        "tier": "core",
        "native_verify": false
    }]' "${FAMILIES_4ROW_FIXTURE}" > "${WORKDIR}/added-arch.json"

OTHER_FAMILIES_BEFORE=$("${ARCHES_SH}" --with-ci "${FAMILIES_4ROW_FIXTURE}" | jq -S '[.[] | select(.family != "ASOFT")] | sort_by(.family)')
OTHER_FAMILIES_AFTER=$("${ARCHES_SH}" --with-ci "${WORKDIR}/added-arch.json" | jq -S '[.[] | select(.family != "ASOFT")] | sort_by(.family)')

assert_eq "the other 3 families' with-ci rows are byte-identical after adding a 2nd ASOFT arch" \
    "${OTHER_FAMILIES_BEFORE}" "${OTHER_FAMILIES_AFTER}"

ASOFT_ID_BEFORE=$("${ARCHES_SH}" --id-for arm 5 "" "" "")
ASOFT_ID_AFTER_A9=$("${ARCHES_SH}" --id-for arm 5 "" "" "")
assert_eq "ASOFT's own id-for mapping is unaffected by table growth (pure function)" \
    "${ASOFT_ID_BEFORE}" "${ASOFT_ID_AFTER_A9}"

echo

# --- 5. --with-ci: exactly one verify per family, and it's bootable --------

echo "=== arches.sh --with-ci: one verify per family, each bootable ==="

WITH_CI=$("${ARCHES_SH}" --with-ci "${FAMILIES_4ROW_FIXTURE}")

FAMILY_COUNT=$(echo "${WITH_CI}" | jq 'length')
UNIQUE_FAMILY_COUNT=$(echo "${WITH_CI}" | jq '[.[].family] | unique | length')
assert_eq "--with-ci emits exactly one row per family (no duplicates)" \
    "${FAMILY_COUNT}" "${UNIQUE_FAMILY_COUNT}"

# The 4-row fixture is 1 arch per family, so 4 families expected.
assert_eq "--with-ci emits 4 families for the 4-row fixture" "4" "${FAMILY_COUNT}"

VERIFY_COUNT=$(echo "${WITH_CI}" | jq '[.[] | select(.verify == null or .verify == "")] | length')
assert_eq "every family row has a non-empty verify arch" "0" "${VERIFY_COUNT}"

# "bootable" == carries a real rootfs pin (target/url/sha256), the
# operational meaning of CI-boot-representative in the current schema
# (matches how tests/apk/rootfs.sh/qemu.sh already treat these fields).
UNBOOTABLE_COUNT=$(echo "${WITH_CI}" | jq '[.[] | select((.rootfs_target // "") == "" or (.rootfs_url // "") == "" or (.rootfs_sha256 // "") == "")] | length')
assert_eq "every emitted verify arch carries a real rootfs pin (bootable)" "0" "${UNBOOTABLE_COUNT}"

# Each verify name must itself be a real arch present in the fixture (a
# bootable ARCH STRING, not a family mnemonic or placeholder).
BAD_VERIFY_NAMES=$(echo "${WITH_CI}" | jq --argjson arches "$(jq -c '[.[].name]' "${FAMILIES_4ROW_FIXTURE}")" \
    '[.[] | select(.verify as $v | ($arches | index($v)) == null)] | length')
assert_eq "every verify name is a real arch string from the fixture" "0" "${BAD_VERIFY_NAMES}"

echo

# --- 6. widened table (S1b): 35 rows, 30 feasible/5 infeasible, 14 families -

echo "=== widened table: 35 rows, 30 feasible / 5 infeasible, 14 families ==="

TOTAL_ROWS=$(jq 'length' "${ARCHES_JSON}")
assert_eq "arches.json has 35 rows (S1b's full Appendix table)" "35" "${TOTAL_ROWS}"

INFEASIBLE_COUNT=$(jq '[.[] | select(.tier == "infeasible")] | length' "${ARCHES_JSON}")
assert_eq "5 infeasible rows" "5" "${INFEASIBLE_COUNT}"

FEASIBLE_COUNT=$(jq '[.[] | select(.tier != "infeasible")] | length' "${ARCHES_JSON}")
assert_eq "30 feasible rows (core + extended)" "30" "${FEASIBLE_COUNT}"

CORE_COUNT=$(jq '[.[] | select(.tier == "core")] | length' "${ARCHES_JSON}")
assert_eq "the original 4 rows stay tier=core" "4" "${CORE_COUNT}"

EXTENDED_COUNT=$(jq '[.[] | select(.tier == "extended")] | length' "${ARCHES_JSON}")
assert_eq "26 new rows are tier=extended" "26" "${EXTENDED_COUNT}"

# infeasible rows carry a blank tuple + a non-null reason; feasible rows the
# reverse -- a drift guard so no row is ever half-classified.
BAD_INFEASIBLE=$(jq '[.[] | select(.tier == "infeasible") | select(.reason == null or .goarch != "")] | length' "${ARCHES_JSON}")
assert_eq "every infeasible row has a non-null reason and blank goarch" "0" "${BAD_INFEASIBLE}"

BAD_FEASIBLE=$(jq '[.[] | select(.tier != "infeasible") | select(.reason != null or .goarch == "")] | length' "${ARCHES_JSON}")
assert_eq "every feasible row has a null reason and non-blank goarch" "0" "${BAD_FEASIBLE}"

echo
echo "=== R1: --validate ITSELF enforces the tier/reason feasibility-duality invariant ==="

# The BAD_INFEASIBLE/BAD_FEASIBLE checks just above prove the two
# feasibility predicates in play across this table's consumers --
# `.reason == null` (build_family_rows/select-matrix's own gate) and
# `.tier != "infeasible"` (--tier-arches/--resolve-republish-arches) --
# agree on the REAL table today. Before R1, that agreement was enforced
# ONLY here, in this test, via a raw jq predicate that --validate itself
# never ran -- a future arches.json edit setting `tier: "extended"` while
# forgetting to null out `reason` (or the reverse) would have passed
# --validate standalone yet silently diverged between consumers. These two
# fixtures are exactly that authoring mistake, in both directions, and
# --validate must now reject each one itself (not merely the jq predicate
# above).

jq '(.[] | select(.name == "mips_24kc") | .tier) |= "extended"
  | (.[] | select(.name == "mips_24kc") | .reason) |= "deliberately mismatched: tier says feasible, reason says infeasible"' \
    "${ARCHES_JSON}" > "${WORKDIR}/bad-tier-reason-mismatch.json"

set +e
"${ARCHES_SH}" --validate "${WORKDIR}/bad-tier-reason-mismatch.json" >"${WORKDIR}/bad-tier-reason-mismatch.out" 2>&1
BAD_TIER_REASON_RC=$?
set -e

if [ "${BAD_TIER_REASON_RC}" -ne 0 ]; then
    log_info "OK: --validate rejects a feasible-tier (extended) row carrying a non-null reason"
else
    log_fail "--validate accepted a feasible tier with a non-null reason (R1 duality violated):
$(cat "${WORKDIR}/bad-tier-reason-mismatch.out")"
fi
assert_contains "R1: --validate names the offending row (mismatched tier/reason)" \
    "$(cat "${WORKDIR}/bad-tier-reason-mismatch.out")" "mips_24kc"

jq '(.[] | select(.tier == "infeasible") | select(.name == "powerpc_8548") | .reason) |= null' \
    "${ARCHES_JSON}" > "${WORKDIR}/bad-infeasible-null-reason.json"

set +e
"${ARCHES_SH}" --validate "${WORKDIR}/bad-infeasible-null-reason.json" >"${WORKDIR}/bad-infeasible-null-reason.out" 2>&1
BAD_INFEASIBLE_NULL_RC=$?
set -e

if [ "${BAD_INFEASIBLE_NULL_RC}" -ne 0 ]; then
    log_info "OK: --validate rejects an infeasible-tier row with its reason nulled back out"
else
    log_fail "--validate accepted an infeasible tier with a null reason (R1 duality violated):
$(cat "${WORKDIR}/bad-infeasible-null-reason.out")"
fi
assert_contains "R1: --validate names the offending row (infeasible tier, null reason)" \
    "$(cat "${WORKDIR}/bad-infeasible-null-reason.out")" "powerpc_8548"

echo
echo "=== widened table: --validate reports exactly 14 families ==="

VALIDATE_OUT=$("${ARCHES_SH}" --validate "${ARCHES_JSON}" 2>&1)
VALIDATE_RC=$?
assert_eq "--validate exits 0 on the widened 35-row table" "0" "${VALIDATE_RC}"
assert_contains "--validate reports 14 families" "${VALIDATE_OUT}" "14 families"

echo
echo "=== widened table: each of the 14 mnemonics is produced by some feasible row ==="

# Derive the family id for every FEASIBLE row's tuple directly via
# --id-for (not --with-ci, which is native_verify:true-gated and by design omits
# the 4 S7b-unverified families) and collect the unique set.
#
# NOTE: deliberately NOT `@tsv` + `IFS=<tab> read` -- tab is still
# classified as "IFS whitespace" even when IFS is set to contain only a
# tab, so POSIX `read` collapses consecutive tab delimiters exactly like
# default word-splitting, silently dropping the empty tuple fields (goarm/
# gomips/etc are "" for most rows) and shifting every later column. A
# non-whitespace separator (`|`, absent from every field's vocabulary) does
# not get collapsed.
DERIVED_FAMILIES=$(jq -r '.[] | select(.tier != "infeasible") | [.goarch, .goarm, .gomips, .gomips64, .go386] | join("|")' "${ARCHES_JSON}" \
    | while IFS='|' read -r ga gm gmips gmips64 g386; do
        "${ARCHES_SH}" --id-for "${ga}" "${gm}" "${gmips}" "${gmips64}" "${g386}"
      done | sort -u)

DERIVED_FAMILY_COUNT=$(echo "${DERIVED_FAMILIES}" | sed '/^$/d' | wc -l | tr -d ' ')
assert_eq "30 feasible rows derive exactly 14 distinct families" "14" "${DERIVED_FAMILY_COUNT}"

for expected_family in A64 A7HF A6HF ASOFT M32BE M32LE M32LEHF M64BE M64LE X86SSE2 X86SOFT AMD64 RV64 LOONG64; do
    # Exact line match (not a substring case-match): M32LE is a literal
    # prefix of M32LEHF, so a substring test would false-positive "M32LE is
    # present" purely from M32LEHF's row, masking a genuine bug.
    if printf '%s\n' "${DERIVED_FAMILIES}" | grep -qx "${expected_family}"; then
        log_info "OK: family ${expected_family} is produced by some feasible row"
    else
        log_fail "family ${expected_family} is NOT produced by any feasible row"
    fi
done

echo

# --- 7. S7a: --with-ci is native_verify:true-driven against the REAL, now-pinned --
# arches.json: exactly the 10 bootable families, the 4 unverified ones
# excluded (not hard-failed), and the aarch64_cortex-a53/arm_cortex-a7
# "sibling also carries a rootfs pin but isn't the true native match" case
# resolves to the RIGHT representative. ------------------------------------

echo "=== S7a: --with-ci on the real arches.json: exactly 10 bootable families ==="

REAL_WITH_CI=$("${ARCHES_SH}" --with-ci "${ARCHES_JSON}")
REAL_WITH_CI_COUNT=$(echo "${REAL_WITH_CI}" | jq 'length')
assert_eq "--with-ci emits 10 rows for the real (S7a-pinned) arches.json" "10" "${REAL_WITH_CI_COUNT}"

EXPECTED_BOOTABLE='["A64","A7HF","AMD64","LOONG64","M32BE","M32LE","M64BE","M64LE","X86SOFT","X86SSE2"]'
REAL_BOOTABLE_FAMILIES=$(echo "${REAL_WITH_CI}" | jq -c '[.[].family] | sort')
assert_eq "the 10 emitted families are exactly the bootable set (RFC §5.6, X86SOFT resolved bootable)" \
    "${EXPECTED_BOOTABLE}" "${REAL_BOOTABLE_FAMILIES}"

for unverified_family in A6HF ASOFT M32LEHF RV64; do
    PRESENT=$(echo "${REAL_WITH_CI}" | jq --arg f "${unverified_family}" '[.[] | select(.family == $f)] | length')
    assert_eq "unverified family ${unverified_family} is excluded from --with-ci (S7b tier, not a hard-fail)" "0" "${PRESENT}"
done

echo

echo "=== S7a: --with-ci resolves A64/A7HF to the TRUE native-match arch, not a sibling that merely carries a rootfs pin ==="

# aarch64_cortex-a53 and arm_cortex-a7 both still carry a (legacy,
# ipk_arches-scoped) rootfs pin, and "aarch64_cortex-a53" < "aarch64_generic"
# lexicographically -- so a naive "first bootable candidate by name"
# tie-break would have picked the WRONG (override-requiring) arch here.
# This is a real regression guard, not a vacuous one: assert the precondition
# (both rows in the family DO carry a rootfs pin) before asserting the
# correct pick.
A64_PINNED_COUNT=$(jq '[.[] | select(.goarch == "arm64") | select(.rootfs_url != null)] | length' "${ARCHES_JSON}")
assert_eq "precondition: more than one A64 row carries a rootfs pin (aarch64_cortex-a53 AND aarch64_generic)" \
    "true" "$([ "${A64_PINNED_COUNT}" -gt 1 ] && echo true || echo false)"

A64_VERIFY=$(echo "${REAL_WITH_CI}" | jq -r '.[] | select(.family == "A64") | .verify')
assert_eq "A64's --with-ci verify arch is aarch64_generic (the true native match), not aarch64_cortex-a53" \
    "aarch64_generic" "${A64_VERIFY}"

A7HF_VERIFY=$(echo "${REAL_WITH_CI}" | jq -r '.[] | select(.family == "A7HF") | .verify')
assert_eq "A7HF's --with-ci verify arch is arm_cortex-a15_neon-vfpv4 (the true native match), not arm_cortex-a7" \
    "arm_cortex-a15_neon-vfpv4" "${A7HF_VERIFY}"

echo

echo "=== S7a: every --with-ci row carries the build tuple + container_arch (what select-matrix --verify-families needs) ==="

MISSING_FIELDS=$(echo "${REAL_WITH_CI}" | jq '[.[] | select(.container_arch == "" or .container_arch == null or .goarch == "" or .goarch == null)] | length')
assert_eq "no --with-ci row is missing container_arch or goarch" "0" "${MISSING_FIELDS}"

echo

echo "=== S7a: --validate rejects an authored native_verify:true row with no rootfs pin ==="

jq '(.[] | select(.name == "arm_cortex-a9") | .native_verify) |= true | (.[] | select(.name == "arm_cortex-a9") | .rootfs_target) |= null' \
    "${ARCHES_JSON}" > "${WORKDIR}/bad-verify-no-rootfs.json"

set +e
"${ARCHES_SH}" --validate "${WORKDIR}/bad-verify-no-rootfs.json" >"${WORKDIR}/bad-verify-no-rootfs.out" 2>&1
BAD_VERIFY_NO_ROOTFS_RC=$?
set -e

if [ "${BAD_VERIFY_NO_ROOTFS_RC}" -ne 0 ]; then
    log_info "OK: --validate rejects a native_verify:true row with no real rootfs pin"
else
    log_fail "--validate accepted a native_verify:true row with no rootfs pin:
$(cat "${WORKDIR}/bad-verify-no-rootfs.out")"
fi

echo
echo "=== S7a: --validate rejects two native_verify:true rows in the same family ==="

# aarch64_cortex-a53 already carries a real rootfs pin (the legacy
# ipk_arches one) and shares the A64 family with aarch64_generic (already
# native_verify:true in the real table) -- flipping ITS native_verify to
# true too is a genuine "two representatives for one family" authoring
# mistake.
jq '(.[] | select(.name == "aarch64_cortex-a53") | .native_verify) |= true' \
    "${ARCHES_JSON}" > "${WORKDIR}/dup-verify.json"

set +e
"${ARCHES_SH}" --validate "${WORKDIR}/dup-verify.json" >"${WORKDIR}/dup-verify.out" 2>&1
DUP_VERIFY_RC=$?
set -e

if [ "${DUP_VERIFY_RC}" -ne 0 ]; then
    log_info "OK: --validate rejects a second native_verify:true row in the A64 family"
else
    log_fail "--validate accepted two native_verify:true rows in one family:
$(cat "${WORKDIR}/dup-verify.out")"
fi

echo
echo "=== S7a: --with-ci itself hard-fails (not silently picks one) on two native_verify:true rows in a family ==="

set +e
"${ARCHES_SH}" --with-ci "${WORKDIR}/dup-verify.json" >"${WORKDIR}/dup-verify-withci.out" 2>&1
DUP_VERIFY_WITHCI_RC=$?
set -e

if [ "${DUP_VERIFY_WITHCI_RC}" -ne 0 ]; then
    log_info "OK: --with-ci hard-fails on two native_verify:true rows in one family"
else
    log_fail "--with-ci silently picked a representative despite two native_verify:true rows:
$(cat "${WORKDIR}/dup-verify-withci.out")"
fi

echo

# --- 8. S7b: --unverified-arches -- the feasible arches of the 4 unverified
# families, reusing --with-ci's own family grouping ------------------------

echo "=== S7b: --unverified-arches on the real arches.json ==="

UNVERIFIED_ARCHES=$("${ARCHES_SH}" --unverified-arches "${ARCHES_JSON}" | sort)

# Independently derive the expected set: every FEASIBLE row whose own
# build-tuple family is one of the 4 known-unverified families (A6HF/ASOFT/
# M32LEHF/RV64, S7a/§5.6) -- via --id-for per row, the same technique
# section 6 above already uses, NOT by re-reading --unverified-arches' own
# output (that would be circular).
EXPECTED_UNVERIFIED=$(jq -r '.[] | select(.tier != "infeasible") | [.name, .goarch, .goarm, .gomips, .gomips64, .go386] | join("|")' "${ARCHES_JSON}" \
    | while IFS='|' read -r nm ga gm gmips gmips64 g386; do
        fam=$("${ARCHES_SH}" --id-for "${ga}" "${gm}" "${gmips}" "${gmips64}" "${g386}")
        case "${fam}" in
            A6HF|ASOFT|M32LEHF|RV64) echo "${nm}" ;;
        esac
      done | sort)

assert_eq "--unverified-arches emits exactly the feasible arches of the 4 unverified families" \
    "${EXPECTED_UNVERIFIED}" "${UNVERIFIED_ARCHES}"

UNVERIFIED_COUNT=$(echo "${UNVERIFIED_ARCHES}" | sed '/^$/d' | wc -l | tr -d ' ')
if [ "${UNVERIFIED_COUNT}" -gt 0 ]; then
    log_info "OK: --unverified-arches emits a non-empty set (${UNVERIFIED_COUNT} arches) -- not a vacuous pass"
else
    log_fail "--unverified-arches emitted an empty set against the real (4-unverified-family) arches.json"
fi

echo
echo "=== S7b: --unverified-arches excludes every boot-verified family's arches ==="

for verified_family in A64 A7HF M32BE M32LE M64BE M64LE X86SSE2 X86SOFT AMD64 LOONG64; do
    VERIFIED_FAMILY_ARCHES=$(jq -r '
        .[] | select(.tier != "infeasible") |
        [.name, .goarch, .goarm, .gomips, .gomips64, .go386] | join("|")
    ' "${ARCHES_JSON}" \
        | while IFS='|' read -r nm ga gm gmips gmips64 g386; do
            fam=$("${ARCHES_SH}" --id-for "${ga}" "${gm}" "${gmips}" "${gmips64}" "${g386}")
            if [ "${fam}" = "${verified_family}" ]; then
                echo "${nm}"
            fi
          done)
    for a in ${VERIFIED_FAMILY_ARCHES}; do
        case "
${UNVERIFIED_ARCHES}
" in
            *"
${a}
"*)
                log_fail "--unverified-arches wrongly includes ${a} (family ${verified_family} is boot-verified)"
                ;;
            *)
                log_info "OK: ${a} (family ${verified_family}, boot-verified) correctly excluded"
                ;;
        esac
    done
done

echo
echo "=== S7b: --unverified-arches excludes every infeasible arch ==="

INFEASIBLE_NAMES=$(jq -r '.[] | select(.tier == "infeasible") | .name' "${ARCHES_JSON}")
for a in ${INFEASIBLE_NAMES}; do
    case "
${UNVERIFIED_ARCHES}
" in
        *"
${a}
"*)
            log_fail "--unverified-arches wrongly includes infeasible arch ${a}"
            ;;
        *)
            log_info "OK: infeasible arch ${a} correctly excluded (different tier entirely)"
            ;;
    esac
done

echo

# --- 9. M1 (code-review HIGH-adjacent finding): `.name` shape guard --------
#
# `.name` flows verbatim into shell text downstream (e.g. publish-feed.sh's
# `xargs -I{} sh -c '... arch="{}" ...'` textual splice) -- a `.name`
# containing shell metacharacters (space, quote, `;`, `$`, backtick, `/`,
# etc) is a command-injection vector at that splice site. The root fix lives
# HERE, at the schema guard: every row's `.name` must match the same safe
# arch-name charclass scripts/detect-arch-drift.sh already uses to filter
# the live OpenWrt index (`^[a-z0-9][a-z0-9_.-]*$`), so a shell-dangerous
# name can never reach arches.json in the first place.
echo "=== M1: --validate rejects a row whose .name is not shell-safe ==="

INJECTION_NAMES='evil; rm -rf /
evil name with spaces
evil"quote
evil$(touch PWNED)
evil`touch PWNED`
UPPERCASE_not_allowed
/etc/passwd
-leading-dash'

# NOTE: deliberately a `for` loop over a newline-only IFS (not `... | while
# read`, a pipeline) -- a pipeline's right-hand side runs in a SUBSHELL under
# POSIX sh (dash), so log_fail's FAIL=1 would be set in a child process and
# silently discarded, letting harness_finish report OK despite real
# failures. Same discipline the VERIFIED_FAMILY_ARCHES loop below already
# uses. Setting IFS to a bare newline (not unsetting it) keeps embedded
# spaces (e.g. "evil name with spaces") as part of one loop item.
_old_ifs="${IFS}"
IFS='
'
for bad_name in ${INJECTION_NAMES}; do
    IFS="${_old_ifs}"
    [ -n "${bad_name}" ] || continue
    jq --arg n "${bad_name}" '(.[0].name) = $n' "${ARCHES_JSON}" > "${WORKDIR}/bad-name.json"

    set +e
    "${ARCHES_SH}" --validate "${WORKDIR}/bad-name.json" >"${WORKDIR}/bad-name.out" 2>&1
    BAD_NAME_RC=$?
    set -e

    if [ "${BAD_NAME_RC}" -ne 0 ]; then
        log_info "OK: --validate rejects injection-shaped name '${bad_name}'"
    else
        log_fail "--validate ACCEPTED injection-shaped name '${bad_name}':
$(cat "${WORKDIR}/bad-name.out")"
    fi
    IFS='
'
done
IFS="${_old_ifs}"

echo
echo "=== M1: --validate passes every real name in arches.json against the safe charclass ==="

# Independent check (not routed through --validate's own pass/fail) that
# every name currently in the table is actually shell-safe -- proves M1's
# fixture-only failures above aren't masking a real row that would already
# fail the new rule (which would make --validate on the unmodified
# arches.json fail too, caught separately above in section 3).
UNSAFE_REAL_NAMES=$(jq -r '.[].name' "${ARCHES_JSON}" | grep -Ev '^[a-z0-9][a-z0-9_.-]*$' || true)
assert_eq "every real arches.json name matches ^[a-z0-9][a-z0-9_.-]*\$" "" "${UNSAFE_REAL_NAMES}"

echo

# --- 9b. R2a (code-review finding, companion to gen-install-arch-block.sh's --
# row-parsing fix): `.reason` must be a single clean printable line -- an
# embedded newline (or other control character) is rejected by --validate
# itself, at the schema, rather than left solely to the generator's own
# (also-fixed, see tests/apk/install-arch-block.sh) defenses. -------------

echo "=== R2a: --validate rejects a .reason containing an embedded newline (injected case-arm-shaped payload) ==="

# Same injection shape tests/apk/install-arch-block.sh's own regression test
# proves is neutralized by the generator: an embedded newline followed by
# text that LOOKS like it could close the current case arm and open a new
# one (") touch PWNED ;;") if it ever escaped the one-row-per-line
# assumption. --validate must refuse this at the source, independent of
# whether the generator's own fix (jq -c row iteration) also happens to
# neutralize it.
MULTILINE_REASON="safe start
evil_arch) touch PWNED_FAMILIES_TEST ;;
        *)"

jq --arg r "${MULTILINE_REASON}" '(.[] | select(.tier == "infeasible") | select(.name == "powerpc_8548") | .reason) = $r' \
    "${ARCHES_JSON}" > "${WORKDIR}/bad-reason-newline.json"

# Precondition: the fixture really does carry an embedded newline (not a
# vacuous test because jq's `--arg` happened to collapse it).
assert_eq "precondition: the fixture's reason really does contain a newline" \
    "true" "$(jq -r '.[] | select(.name == "powerpc_8548") | (.reason | test("\n"))' "${WORKDIR}/bad-reason-newline.json")"

set +e
"${ARCHES_SH}" --validate "${WORKDIR}/bad-reason-newline.json" >"${WORKDIR}/bad-reason-newline.out" 2>&1
BAD_REASON_NEWLINE_RC=$?
set -e

if [ "${BAD_REASON_NEWLINE_RC}" -ne 0 ]; then
    log_info "OK: --validate rejects a .reason containing an embedded newline"
else
    log_fail "--validate ACCEPTED a .reason with an embedded, injection-shaped newline:
$(cat "${WORKDIR}/bad-reason-newline.out")"
fi
assert_contains "R2a: --validate names the offending row (multi-line reason)" \
    "$(cat "${WORKDIR}/bad-reason-newline.out")" "powerpc_8548"

echo

# --- 10. M4 (code-review finding): --tier-arches accessor + drift guard ----
#
# `select(.tier == "core") | .name` used to be hand-authored independently
# in FOUR places (tailscale-package/build-apk.sh, scripts/publish-feed.sh's
# committed-core depublish guard, .github/workflows/build-tailscale.yaml's
# two republish-feed loops). All four now route through
# `arches.sh --tier-arches`. This section asserts the accessor itself is
# correct, AND (a grep-based drift assertion, mirroring
# tests/apk/install-arch-block.sh's byte-identity discipline) that none of
# those four authored jq calls has silently come back.

echo "=== M4: --tier-arches core on the real arches.json ==="

TIER_CORE_ARCHES=$("${ARCHES_SH}" --tier-arches core "${ARCHES_JSON}")
EXPECTED_CORE='aarch64_cortex-a53
arm_cortex-a7
mips_24kc
mipsel_24kc'
assert_eq "--tier-arches core emits exactly the 4 historical core arches, sorted" \
    "${EXPECTED_CORE}" "${TIER_CORE_ARCHES}"

TIER_EXTENDED_COUNT=$("${ARCHES_SH}" --tier-arches extended "${ARCHES_JSON}" | sed '/^$/d' | wc -l | tr -d ' ')
assert_eq "--tier-arches extended emits 26 arches" "26" "${TIER_EXTENDED_COUNT}"

TIER_INFEASIBLE_COUNT=$("${ARCHES_SH}" --tier-arches infeasible "${ARCHES_JSON}" | sed '/^$/d' | wc -l | tr -d ' ')
assert_eq "--tier-arches infeasible emits 5 arches" "5" "${TIER_INFEASIBLE_COUNT}"

echo
echo "=== M4: --tier-arches hard-fails on an unknown tier ==="

set +e
"${ARCHES_SH}" --tier-arches bogus "${ARCHES_JSON}" >"${WORKDIR}/bad-tier.out" 2>&1
BAD_TIER_RC=$?
set -e

if [ "${BAD_TIER_RC}" -ne 0 ]; then
    log_info "OK: --tier-arches rejects an unknown tier 'bogus'"
else
    log_fail "--tier-arches accepted an unknown tier 'bogus':
$(cat "${WORKDIR}/bad-tier.out")"
fi

echo
echo "=== M4: no authored 'select(.tier == \"core\")' jq call remains at the four consumer sites ==="

# Anchored on 'jq' + the predicate together (not the bare predicate string
# alone) so this doesn't false-positive on the EXPLANATORY comments this
# same refactor left behind at each call site (which mention the retired
# predicate in prose, without invoking jq).
M4_SITES="${REPO_ROOT}/tailscale-package/build-apk.sh ${REPO_ROOT}/scripts/publish-feed.sh ${REPO_ROOT}/.github/workflows/build-tailscale.yaml"
M4_LEAKED=$(grep -rnE 'jq.*select\(\.tier == "core"\)' ${M4_SITES} || true)
assert_eq "no authored jq 'select(.tier == \"core\")' call remains in build-apk.sh/publish-feed.sh/build-tailscale.yaml" \
    "" "${M4_LEAKED}"

echo
echo "=== M4: select-matrix.sh --ipk-arches (non-PR) computes the SAME name set as --tier-arches core ==="

SELECT_MATRIX="${REPO_ROOT}/scripts/select-matrix.sh"
if [ -x "${SELECT_MATRIX}" ]; then
    SELECT_MATRIX_CORE=$("${SELECT_MATRIX}" workflow_dispatch --ipk-arches "${ARCHES_JSON}" | jq -r '[.[].name] | sort | .[]')
    assert_eq "select-matrix.sh --ipk-arches (workflow_dispatch) name set == arches.sh --tier-arches core" \
        "${TIER_CORE_ARCHES}" "${SELECT_MATRIX_CORE}"
else
    log_fail "scripts/select-matrix.sh not found or not executable at ${SELECT_MATRIX}"
fi

echo

# --- 11. M5 (code-review finding): --compile-families accessor -------------
#
# select-matrix.sh --compile-families used to re-derive the family grouping
# independently (a per-row --id-for subprocess loop + its own group_by).
# It now delegates wholesale to arches.sh --compile-families, built on
# the SAME build_family_rows() grouping --with-ci/--unverified-arches
# already share. This section exercises the new mode directly (not just
# through select-matrix.sh) and cross-checks the two agree.

echo "=== M5: --compile-families on the full feasible (gate-flip) set ==="

FEASIBLE_GATED="${WORKDIR}/feasible-gated.json"
jq -c '[.[] | select(.reason == null)]' "${ARCHES_JSON}" > "${FEASIBLE_GATED}"

COMPILE_FAMILIES_OUT=$("${ARCHES_SH}" --compile-families "${FEASIBLE_GATED}")
assert_eq "--compile-families emits 14 family rows for the full feasible set" \
    "14" "$(echo "${COMPILE_FAMILIES_OUT}" | jq 'length')"
assert_eq "--compile-families' arch lists sum to 30 (every feasible arch, no fewer)" \
    "30" "$(echo "${COMPILE_FAMILIES_OUT}" | jq '[.[].arches[]] | length')"

# Every family row's own tuple must re-derive to that same family id via
# --id-for (the pure fn build_family_rows itself is built on) -- a
# structural self-consistency check independent of select-matrix.sh.
BAD_TUPLE_FAMILIES=$(echo "${COMPILE_FAMILIES_OUT}" | jq -r '.[] | [.family, .goarch, .goarm, .gomips, .gomips64, .go386] | join("|")' \
    | while IFS='|' read -r fam ga gm gmips gmips64 g386; do
        derived=$("${ARCHES_SH}" --id-for "${ga}" "${gm}" "${gmips}" "${gmips64}" "${g386}")
        if [ "${derived}" != "${fam}" ]; then
            echo "${fam} derived-as ${derived}"
        fi
      done)
assert_eq "every --compile-families row's own tuple re-derives to its own family id" "" "${BAD_TUPLE_FAMILIES}"

echo
echo "=== M5: --compile-families is order-independent (row-shuffled input yields the same view) ==="

SHUFFLED_GATED="${WORKDIR}/feasible-gated-shuffled.json"
jq '[.[3], .[1], .[0], .[2]] + .[4:]' "${FEASIBLE_GATED}" > "${SHUFFLED_GATED}"
SHUFFLED_COMPILE=$("${ARCHES_SH}" --compile-families "${SHUFFLED_GATED}" | jq -S .)
ORIGINAL_COMPILE=$(echo "${COMPILE_FAMILIES_OUT}" | jq -S .)
assert_eq "shuffling the gated input's row order does not change --compile-families' view" \
    "${ORIGINAL_COMPILE}" "${SHUFFLED_COMPILE}"

echo
echo "=== M5: select-matrix.sh --compile-families agrees with arches.sh --compile-families on the same gated input ==="

if [ -x "${SELECT_MATRIX}" ]; then
    SELECT_MATRIX_COMPILE=$("${SELECT_MATRIX}" workflow_dispatch --compile-families "${ARCHES_JSON}" | jq -S .)
    assert_eq "select-matrix.sh --compile-families (workflow_dispatch) == arches.sh --compile-families on the same reason==null gate" \
        "${ORIGINAL_COMPILE}" "${SELECT_MATRIX_COMPILE}"
else
    log_fail "scripts/select-matrix.sh not found or not executable at ${SELECT_MATRIX}"
fi

echo
echo "=== M5: no authored per-row --id-for grouping loop remains in select-matrix.sh ==="

# select-matrix.sh legitimately still calls arches.sh for other things
# (--with-ci for --verify-families, --tier-arches for --ipk-arches); what
# must be gone is the --compile-families code path's own per-row --id-for
# subprocess loop. Anchor on the retired loop's own distinctive error
# message string (unique to that deleted code, never reused elsewhere) --
# NOT a bare grep for '--id-for' by name.
M5_LEAKED=$(grep -n "select-matrix.sh --compile-families: arch '" "${SELECT_MATRIX}" || true)
assert_eq "select-matrix.sh no longer contains its own --compile-families unmapped-tuple error path (now arches.sh's job)" \
    "" "${M5_LEAKED}"

echo

# --- 12. M8 (code-review finding): row-level `native_verify` boolean is a --
# DIFFERENT thing from --with-ci's OUTPUT key `verify` (an arch NAME
# string), and the schema now lets a reader/validator -- not just prose --
# tell "has a rootfs pin" (rootfs_* present) apart from "IS the family's
# native-match representative" (native_verify: true). ------------------------

echo "=== M8: the arches.json schema uses 'native_verify', never the old bare 'verify' key ==="

# Every row carries native_verify as a real (present, not `// default`)
# key, and the old key name is gone entirely -- a reader can no longer
# mistake the row-level boolean for --with-ci's own OUTPUT key `verify`
# (they used to share one name; see scripts/arches.sh's header comment).
MISSING_NATIVE_VERIFY_KEY=$(jq '[.[] | select(has("native_verify") | not)] | length' "${ARCHES_JSON}")
assert_eq "every row has a 'native_verify' key" "0" "${MISSING_NATIVE_VERIFY_KEY}"

STALE_VERIFY_KEY=$(jq '[.[] | select(has("verify"))] | length' "${ARCHES_JSON}")
assert_eq "no row still carries the old bare 'verify' key (M8 rename is total, not partial)" "0" "${STALE_VERIFY_KEY}"

echo
echo "=== M8: --with-ci's OUTPUT key stays 'verify' (external contract, e.g. build-tailscale.yaml's matrix.family.verify, is unaffected by the row-level rename) ==="

WITH_CI_KEYS=$(echo "${REAL_WITH_CI}" | jq -r '[.[0] | keys[]] | sort | join(",")')
case ",${WITH_CI_KEYS}," in
    *,verify,*)
        log_info "OK: --with-ci still emits the OUTPUT key 'verify' (arch-name string, unrenamed)"
        ;;
    *)
        log_fail "--with-ci no longer emits the OUTPUT key 'verify' -- this would break select-matrix.sh --verify-families / build-tailscale.yaml's matrix.family.verify: ${WITH_CI_KEYS}"
        ;;
esac

echo
echo "=== M8: it is LEGAL for a row to carry a real rootfs pin with native_verify:false -- the core-ARM install-verify-only case, structurally distinct from 'IS the native-match rep' ==="

# aarch64_cortex-a53 and arm_cortex-a7 are exactly the S7a-found pair: both
# still carry a full rootfs pin (needed by the legacy ipk_arches-scoped
# install-verify tests) but are NOT their family's native-match arch, so
# both are native_verify:false. This is the precise distinction M8 makes
# structural: rootfs_* means "has a pin", native_verify means "IS the
# representative" -- independent facts. Assert the precondition (both
# still pinned, still false) before asserting --validate treats this as
# legal, not a violation.
for core_arm_row in aarch64_cortex-a53 arm_cortex-a7; do
    ROW=$(jq -c --arg n "${core_arm_row}" '.[] | select(.name == $n)' "${ARCHES_JSON}")
    ROW_NATIVE_VERIFY=$(echo "${ROW}" | jq -r '.native_verify')
    ROW_HAS_PIN=$(echo "${ROW}" | jq -r 'if (.rootfs_target // "") != "" and (.rootfs_url // "") != "" and (.rootfs_sha256 // "") != "" then "true" else "false" end')

    assert_eq "${core_arm_row}: native_verify is false (not the native-match rep)" "false" "${ROW_NATIVE_VERIFY}"
    assert_eq "${core_arm_row}: still carries a real rootfs pin despite native_verify:false (has-a-pin != is-the-rep)" "true" "${ROW_HAS_PIN}"
done

# The real arches.json (unmodified, containing exactly this "pinned but
# native_verify:false" pair) already passed --validate in section 3 above
# -- restate that here, scoped explicitly to this invariant, so a future
# reader sees the legality asserted right next to the fact it's legalizing
# (not just inferred transitively from an earlier, differently-labeled
# section).
if "${ARCHES_SH}" --validate "${ARCHES_JSON}" >"${WORKDIR}/m8-legal.out" 2>&1; then
    log_info "OK: --validate accepts the real table's pinned-but-native_verify:false core-ARM rows (legal, not a schema violation)"
else
    log_fail "--validate rejected the real arches.json, which legitimately carries rootfs pins on native_verify:false rows:
$(cat "${WORKDIR}/m8-legal.out")"
fi

echo

harness_finish "tests/apk/arches.sh"
