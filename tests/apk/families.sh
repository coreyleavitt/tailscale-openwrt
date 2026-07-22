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
#   7. S7a: `--with-ci` is verify:true-flag-driven, not "first row with a
#      rootfs pin" -- a family with NO verify:true row is EXCLUDED from the
#      view (not hard-failed: that's the S7b unverified tier), a family
#      with a verify:true row gets exactly that row back (even when a
#      SIBLING row in the same family also carries a rootfs pin -- the
#      exact aarch64_cortex-a53-vs-aarch64_generic case S7a found), and
#      `--validate` catches two authoring mistakes: a verify:true row
#      lacking a real rootfs pin, and two verify:true rows in one family.
#      Exercised against the REAL (now S7a-pinned) arches.json: exactly 10
#      bootable families (A64/A7HF/M32BE/M32LE/M64BE/M64LE/X86SSE2/
#      X86SOFT/AMD64/LOONG64), the other 4 (A6HF/ASOFT/M32LEHF/RV64)
#      excluded.
#
# Usage: sh tests/apk/families.sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
FAMILIES_SH="${REPO_ROOT}/scripts/families.sh"
ARCHES_JSON="${REPO_ROOT}/arches.json"

# S1b widened the real arches.json to the full 35-row Appendix table; S7a
# then pinned rootfs images + set `verify: true` for the 10 CI-bootable
# families (§5.6) -- 4 families (A6HF/ASOFT/M32LEHF/RV64) remain genuinely
# unbootable (no generic rootfs exists upstream) and stay `verify: false`
# on every row, so `--with-ci` excludes them (the S7b unverified tier). The
# id-stability / one-verify-per-family sections below are unit tests of
# `--with-ci`'s OWN properties (order-independence, verify:true-flag
# selection over a fragile "first with a rootfs pin" inference) -- they
# exercise a frozen 4-row fixture (one arch per family, every family
# verify:true) so they stay independent of how many families the live
# table happens to have pinned at any given time.
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
# genuine second member to an existing family, not a new one. verify:false --
# arm_cortex-a7 (already verify:true in the fixture) stays ASOFT's ONE
# representative; a second verify:true row in the same family is a schema
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
        "verify": false
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
# --id-for (not --with-ci, which is verify:true-gated and by design omits
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

echo

# --- 7. S7a: --with-ci is verify:true-driven against the REAL, now-pinned --
# arches.json: exactly the 10 bootable families, the 4 unverified ones
# excluded (not hard-failed), and the aarch64_cortex-a53/arm_cortex-a7
# "sibling also carries a rootfs pin but isn't the true native match" case
# resolves to the RIGHT representative. ------------------------------------

echo "=== S7a: --with-ci on the real arches.json: exactly 10 bootable families ==="

REAL_WITH_CI=$("${FAMILIES_SH}" --with-ci "${ARCHES_JSON}")
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

echo "=== S7a: --validate rejects an authored verify:true row with no rootfs pin ==="

jq '(.[] | select(.name == "arm_cortex-a9") | .verify) |= true | (.[] | select(.name == "arm_cortex-a9") | .rootfs_target) |= null' \
    "${ARCHES_JSON}" > "${WORKDIR}/bad-verify-no-rootfs.json"

set +e
"${FAMILIES_SH}" --validate "${WORKDIR}/bad-verify-no-rootfs.json" >"${WORKDIR}/bad-verify-no-rootfs.out" 2>&1
BAD_VERIFY_NO_ROOTFS_RC=$?
set -e

if [ "${BAD_VERIFY_NO_ROOTFS_RC}" -ne 0 ]; then
    log_info "OK: --validate rejects a verify:true row with no real rootfs pin"
else
    log_fail "--validate accepted a verify:true row with no rootfs pin:
$(cat "${WORKDIR}/bad-verify-no-rootfs.out")"
fi

echo
echo "=== S7a: --validate rejects two verify:true rows in the same family ==="

# aarch64_cortex-a53 already carries a real rootfs pin (the legacy
# ipk_arches one) and shares the A64 family with aarch64_generic (already
# verify:true in the real table) -- flipping ITS verify to true too is a
# genuine "two representatives for one family" authoring mistake.
jq '(.[] | select(.name == "aarch64_cortex-a53") | .verify) |= true' \
    "${ARCHES_JSON}" > "${WORKDIR}/dup-verify.json"

set +e
"${FAMILIES_SH}" --validate "${WORKDIR}/dup-verify.json" >"${WORKDIR}/dup-verify.out" 2>&1
DUP_VERIFY_RC=$?
set -e

if [ "${DUP_VERIFY_RC}" -ne 0 ]; then
    log_info "OK: --validate rejects a second verify:true row in the A64 family"
else
    log_fail "--validate accepted two verify:true rows in one family:
$(cat "${WORKDIR}/dup-verify.out")"
fi

echo
echo "=== S7a: --with-ci itself hard-fails (not silently picks one) on two verify:true rows in a family ==="

set +e
"${FAMILIES_SH}" --with-ci "${WORKDIR}/dup-verify.json" >"${WORKDIR}/dup-verify-withci.out" 2>&1
DUP_VERIFY_WITHCI_RC=$?
set -e

if [ "${DUP_VERIFY_WITHCI_RC}" -ne 0 ]; then
    log_info "OK: --with-ci hard-fails on two verify:true rows in one family"
else
    log_fail "--with-ci silently picked a representative despite two verify:true rows:
$(cat "${WORKDIR}/dup-verify-withci.out")"
fi

harness_finish "tests/apk/families.sh"
