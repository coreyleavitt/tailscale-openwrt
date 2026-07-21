#!/bin/sh
# tests/apk/families.sh
#
# Slices S1a+S1b test (RFC docs/rfc-apk-arch-coverage.md §5.2 + Slices):
# the v2 `arches.json` fields (goarm/gomips/gomips64/go386/float/reason/tier),
# the S1b widen to the full 35-row Appendix table (30 feasible + 5
# infeasible, gated inert per §5.8), plus scripts/families.sh -- the pure,
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
#
# Usage: sh tests/apk/families.sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
FAMILIES_SH="${REPO_ROOT}/scripts/families.sh"
ARCHES_JSON="${REPO_ROOT}/arches.json"

# S1b widened the real arches.json to the full 35-row Appendix table, but
# left rootfs pinning for the 26 new `extended` rows to S7a (§5.8 -- the
# widen must stay inert). That means most of the 14 families now have ZERO
# rootfs-pinned rows in the live table, by design -- `--with-ci`'s own
# invariant ("every family has exactly one bootable verify arch", enforced
# since S1a) correctly hard-fails on that. The id-stability / one-verify-
# per-family sections below are unit tests of `--with-ci`'s OWN properties
# (order-independence, bootable-representative selection), not an assertion
# that production data is S7a-complete -- so they exercise a frozen 4-row
# fixture (the S1a-era table, one arch per family, every family bootable)
# instead of the live, still-being-migrated arches.json.
FAMILIES_4ROW_FIXTURE="${SCRIPT_DIR}/fixtures/families-4row.json"

# shellcheck source=tests/apk/lib.sh
. "${SCRIPT_DIR}/lib.sh"

require_cmd jq

if [ ! -f "${FAMILIES_SH}" ]; then
    log_fail "scripts/families.sh not found at ${FAMILIES_SH}"
    harness_finish "tests/apk/families.sh"
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

echo "=== families.sh --id-for: 4 present tuples ==="

assert_eq "id-for aarch64_cortex-a53 tuple -> A64" "A64" \
    "$("${FAMILIES_SH}" --id-for arm64 "" "" "" "")"
assert_eq "id-for arm_cortex-a7 tuple -> ASOFT" "ASOFT" \
    "$("${FAMILIES_SH}" --id-for arm 5 "" "" "")"
assert_eq "id-for mips_24kc tuple -> M32BE" "M32BE" \
    "$("${FAMILIES_SH}" --id-for mips "" softfloat "" "")"
assert_eq "id-for mipsel_24kc tuple -> M32LE" "M32LE" \
    "$("${FAMILIES_SH}" --id-for mipsle "" softfloat "" "")"

echo
echo "=== families.sh --id-for: hard-fail on an unmapped tuple ==="

set +e
BOGUS_OUT=$("${FAMILIES_SH}" --id-for sparc64 "" "" "" "" 2>"${WORKDIR}/bogus.err")
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

echo "=== families.sh --validate: real arches.json passes ==="

if "${FAMILIES_SH}" --validate "${ARCHES_JSON}" >"${WORKDIR}/validate-good.out" 2>&1; then
    log_info "OK: --validate passes on the real arches.json"
else
    log_fail "--validate failed on the real arches.json:
$(cat "${WORKDIR}/validate-good.out")"
fi

echo
echo "=== families.sh --validate: fixtured typo'd enum fails ==="

jq '(.[] | select(.name == "mips_24kc") | .float) |= "sof"' "${ARCHES_JSON}" \
    > "${WORKDIR}/bad-enum.json"

set +e
"${FAMILIES_SH}" --validate "${WORKDIR}/bad-enum.json" >"${WORKDIR}/bad-enum.out" 2>&1
BAD_ENUM_RC=$?
set -e

if [ "${BAD_ENUM_RC}" -ne 0 ]; then
    log_info "OK: --validate rejects a typo'd float enum ('sof')"
else
    log_fail "--validate accepted a typo'd float enum ('sof'):
$(cat "${WORKDIR}/bad-enum.out")"
fi

echo
echo "=== families.sh --validate: fixtured unmapped tuple fails ==="

jq '(.[] | select(.name == "mips_24kc") | .goarm) |= "3"' "${ARCHES_JSON}" \
    > "${WORKDIR}/bad-tuple.json"

set +e
"${FAMILIES_SH}" --validate "${WORKDIR}/bad-tuple.json" >"${WORKDIR}/bad-tuple.out" 2>&1
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

ORIG_FAMILIES=$("${FAMILIES_SH}" --with-ci "${FAMILIES_4ROW_FIXTURE}" | jq -S 'sort_by(.family)')
SHUFFLED_FAMILIES=$("${FAMILIES_SH}" --with-ci "${WORKDIR}/shuffled.json" | jq -S 'sort_by(.family)')

assert_eq "with-ci output is identical (as a set) regardless of row order" \
    "${ORIG_FAMILIES}" "${SHUFFLED_FAMILIES}"

echo
echo "=== id-stability: adding a 2nd arch to an existing family leaves other families' ids untouched ==="

# arm_cortex-a9 (bare) shares arm_cortex-a7's exact build tuple (arm/GOARM=5,
# softfloat) -- same family, ASOFT (§4 Appendix) -- so this fixture adds a
# genuine second member to an existing family, not a new one.
jq '. + [{
        "name": "arm_cortex-a9",
        "goarch": "arm", "goarm": "5", "gomips": "", "gomips64": "", "go386": "",
        "endian": "little", "float": "soft", "reason": null,
        "rootfs_target": "armsr/armv7",
        "canary": false,
        "rootfs_url": "https://downloads.openwrt.org/releases/25.12.0/targets/armsr/armv7/openwrt-25.12.0-armsr-armv7-rootfs.tar.gz",
        "rootfs_sha256": "97bd0ac74bf7e9473162449932f7e336e509da467e5ce45d960716934f77e5ce",
        "container_arch": "armv7",
        "tier": "core"
    }]' "${FAMILIES_4ROW_FIXTURE}" > "${WORKDIR}/added-arch.json"

OTHER_FAMILIES_BEFORE=$("${FAMILIES_SH}" --with-ci "${FAMILIES_4ROW_FIXTURE}" | jq -S '[.[] | select(.family != "ASOFT")] | sort_by(.family)')
OTHER_FAMILIES_AFTER=$("${FAMILIES_SH}" --with-ci "${WORKDIR}/added-arch.json" | jq -S '[.[] | select(.family != "ASOFT")] | sort_by(.family)')

assert_eq "the other 3 families' with-ci rows are byte-identical after adding a 2nd ASOFT arch" \
    "${OTHER_FAMILIES_BEFORE}" "${OTHER_FAMILIES_AFTER}"

ASOFT_ID_BEFORE=$("${FAMILIES_SH}" --id-for arm 5 "" "" "")
ASOFT_ID_AFTER_A9=$("${FAMILIES_SH}" --id-for arm 5 "" "" "")
assert_eq "ASOFT's own id-for mapping is unaffected by table growth (pure function)" \
    "${ASOFT_ID_BEFORE}" "${ASOFT_ID_AFTER_A9}"

echo

# --- 5. --with-ci: exactly one verify per family, and it's bootable --------

echo "=== families.sh --with-ci: one verify per family, each bootable ==="

WITH_CI=$("${FAMILIES_SH}" --with-ci "${FAMILIES_4ROW_FIXTURE}")

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
echo "=== widened table: --validate reports exactly 14 families ==="

VALIDATE_OUT=$("${FAMILIES_SH}" --validate "${ARCHES_JSON}" 2>&1)
VALIDATE_RC=$?
assert_eq "--validate exits 0 on the widened 35-row table" "0" "${VALIDATE_RC}"
assert_contains "--validate reports 14 families" "${VALIDATE_OUT}" "14 families"

echo
echo "=== widened table: each of the 14 mnemonics is produced by some feasible row ==="

# Derive the family id for every FEASIBLE row's tuple directly via
# --id-for (never --with-ci, which is rootfs-pin-gated and not yet
# meaningful for the 10 not-core families until S7a pins their rootfs) and
# collect the unique set.
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
        "${FAMILIES_SH}" --id-for "${ga}" "${gm}" "${gmips}" "${gmips64}" "${g386}"
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

harness_finish "tests/apk/families.sh"
