#!/bin/sh
# tests/apk/docs-arch-coverage.sh
#
# Slice S8 (RFC docs/rfc-apk-arch-coverage.md §5.7 + Slices S8): drift guard
# for the docs that describe apk feed arch coverage (README.md,
# docs/INSTALL.md, docs/MAINTAINING.md). S8 reframed those docs from a
# stale "currently 4 arches" claim to the real 30-arch/14-family coverage,
# and introduced a drift-prone list (the "unverified tier" -- feasible
# arches that are published but never CI-boot-verified) that has exactly
# one authoritative source: `scripts/families.sh --unverified-arches`. This
# is the test that keeps the doc copy of that list from silently rotting,
# the same way tests/apk/install-arch-block.sh's Part D keeps the
# infeasible-arch install.sh block honest.
#
# Pure text/jq assertions against the committed docs + arches.json --
# hermetic, no network, no docker.
#
# Covers:
#   A. The unverified-tier arch list embedded in docs/INSTALL.md (between
#      the BEGIN/END markers) matches `scripts/families.sh
#      --unverified-arches` exactly (as a set -- order is not asserted,
#      since neither the doc nor the script promises one). A2 is the
#      RED-proof control: the exact same comparison, run against a
#      deliberately-corrupted copy of the extracted list, must FAIL --
#      proving the assertion isn't vacuously true.
#   B. None of README.md/docs/INSTALL.md/docs/MAINTAINING.md contain the
#      stale "the feed is limited to 4 arches" claim the S8 slice fixed
#      (the exact phrasings that were live in the docs before S8). B2 is
#      the RED-proof control: the same check run against a synthetic
#      string that DOES contain the stale phrasing must FAIL.
#   C. Every arch-name-shaped inline-backtick token in README.md/
#      docs/INSTALL.md (filtered to tokens whose underscore-delimited
#      prefix is a real GOARCH-family prefix, derived from arches.json
#      itself -- not a hardcoded allowlist) actually exists as a row name
#      in arches.json. Catches a renamed/typo'd/removed arch left behind
#      as a stale doc example.
#
# Usage: sh tests/apk/docs-arch-coverage.sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
FAMILIES_SH="${REPO_ROOT}/scripts/families.sh"
ARCHES_JSON="${REPO_ROOT}/arches.json"
README="${REPO_ROOT}/README.md"
INSTALL_MD="${REPO_ROOT}/docs/INSTALL.md"
MAINTAINING_MD="${REPO_ROOT}/docs/MAINTAINING.md"

# shellcheck source=tests/apk/lib.sh
. "${SCRIPT_DIR}/lib.sh"

require_cmd jq

for f in "${FAMILIES_SH}" "${ARCHES_JSON}" "${README}" "${INSTALL_MD}" "${MAINTAINING_MD}"; do
    if [ ! -f "${f}" ]; then
        echo "FAIL: required file not found: ${f}" >&2
        exit 1
    fi
done

WORKDIR=$(mktemp -d)
cleanup() { rm -rf "${WORKDIR}"; }
trap cleanup EXIT

# =====================================================================
# Part A -- unverified-tier list drift guard
# =====================================================================
echo ""
echo "############################################"
echo "### Part A: unverified-tier list matches scripts/families.sh --unverified-arches"
echo "############################################"

extract_unverified_block() {
    # extract_unverified_block file -- prints one arch name per line, taken
    # from `- \`arch\`` bullets between the BEGIN/END markers in <file>.
    awk '
        /^<!-- BEGIN unverified-tier-arches/ { grab=1; next }
        /^<!-- END unverified-tier-arches/ { grab=0 }
        grab { print }
    ' "$1" | sed -n 's/^- `\(.*\)`$/\1/p'
}

# doc_matches_expected doc_list expected_list -- prints "MATCH" or "DRIFT"
# after comparing both lists as SETS (sorted, deduped) -- the comparison
# logic Part A2 below proves is not vacuous.
doc_matches_expected() {
    _doc_sorted=$(printf '%s\n' "$1" | sort -u)
    _expected_sorted=$(printf '%s\n' "$2" | sort -u)
    if [ "${_doc_sorted}" = "${_expected_sorted}" ]; then
        echo "MATCH"
    else
        echo "DRIFT"
    fi
}

DOC_UNVERIFIED=$(extract_unverified_block "${INSTALL_MD}")
EXPECTED_UNVERIFIED=$("${FAMILIES_SH}" --unverified-arches "${ARCHES_JSON}")

assert_eq "A1: docs/INSTALL.md actually contains a non-empty unverified-tier block" \
    "1" "$([ -n "${DOC_UNVERIFIED}" ] && echo 1 || echo 0)"

if [ "$(doc_matches_expected "${DOC_UNVERIFIED}" "${EXPECTED_UNVERIFIED}")" = "MATCH" ]; then
    log_info "OK: A2 (GREEN): docs/INSTALL.md unverified-tier list matches families.sh --unverified-arches exactly"
else
    log_fail "A2: docs/INSTALL.md unverified-tier list has DRIFTED from families.sh --unverified-arches -- regenerate the list between the BEGIN/END markers"
    printf '%s\n' "${DOC_UNVERIFIED}" | sort -u > "${WORKDIR}/a2-doc.txt"
    printf '%s\n' "${EXPECTED_UNVERIFIED}" | sort -u > "${WORKDIR}/a2-expected.txt"
    diff "${WORKDIR}/a2-doc.txt" "${WORKDIR}/a2-expected.txt" >&2 || true
fi

# --- A3 (RED-proof control): the SAME comparison, against a deliberately
# corrupted copy of the doc list (one arch dropped, one bogus arch added),
# must report DRIFT -- proves doc_matches_expected() can actually fail and
# A2 above isn't vacuously true.
CORRUPTED_UNVERIFIED=$(printf '%s\n' "${EXPECTED_UNVERIFIED}" | tail -n +2)
CORRUPTED_UNVERIFIED="${CORRUPTED_UNVERIFIED}
totally_bogus_arch_that_does_not_exist"
assert_eq "A3 (RED-proof control): a mutated list is correctly detected as DRIFT" \
    "DRIFT" "$(doc_matches_expected "${CORRUPTED_UNVERIFIED}" "${EXPECTED_UNVERIFIED}")"

# =====================================================================
# Part B -- no stale "feed is limited to 4 arches" claim
# =====================================================================
echo ""
echo "############################################"
echo "### Part B: no stale 4-arch-limit phrasing"
echo "############################################"

# The exact phrasings that were live in the docs before S8 fixed them
# (README.md's "currently the four above" and docs/INSTALL.md's "currently
# \`aarch64_cortex-a53\`, \`arm_cortex-a7\`, \`mips_24kc\`, \`mipsel_24kc\`").
STALE_PHRASE_1="currently the four"
STALE_PHRASE_2="currently \`aarch64_cortex-a53\`, \`arm_cortex-a7\`, \`mips_24kc\`, \`mipsel_24kc\`"

for docfile in "${README}" "${INSTALL_MD}" "${MAINTAINING_MD}"; do
    _relname=$(basename "${docfile}")
    _content=$(cat "${docfile}")
    assert_not_contains "B: ${_relname} does not contain stale phrase 1 ('${STALE_PHRASE_1}')" \
        "${_content}" "${STALE_PHRASE_1}"
    assert_not_contains "B: ${_relname} does not contain stale phrase 2 (the hardcoded 4-arch list)" \
        "${_content}" "${STALE_PHRASE_2}"
done

# --- B-control (RED-proof control): the same haystack/needle logic
# assert_not_contains uses, run against a synthetic string that DOES
# contain the stale phrasing, must detect it -- proves the check isn't
# vacuously passing on any input. Uses a side-effect-free re-check (rather
# than calling assert_not_contains itself) so a passing run doesn't emit a
# confusing FAIL: line for an intentionally-failing control case.
SYNTHETIC_STALE="apk update will 404 if your arch isn't published yet (currently the four above)."
case "${SYNTHETIC_STALE}" in
    *"${STALE_PHRASE_1}"*)
        log_info "OK: B-control (RED-proof): synthetic string containing the stale phrase is correctly detected as containing it"
        ;;
    *)
        log_fail "B-control: synthetic string containing the stale phrase was NOT detected -- the guard is vacuous"
        ;;
esac

# =====================================================================
# Part C -- arch-name examples in the docs actually exist in arches.json
# =====================================================================
echo ""
echo "############################################"
echo "### Part C: arch-name examples in README/INSTALL exist in arches.json"
echo "############################################"

# Real GOARCH-family prefixes, derived from arches.json itself (every row's
# name is <prefix>_<variant>, or the bare "x86_64" case) -- not a hardcoded
# allowlist, so this stays correct if a 15th family/prefix is ever added.
PREFIXES=" $(jq -r '.[].name' "${ARCHES_JSON}" | sed -E 's/^([a-z0-9]+)_.*/\1/' | sort -u | tr '\n' ' ')"

# Candidate tokens: inline single-backtick spans matching the arch-name
# shape (lowercase start, at least one underscore-delimited segment,
# digits/letters/hyphens only -- excludes UPPER_CASE shell vars, dotted
# filenames/domains, and hyphen-only package names like gl-sdk4-tailscale).
CANDIDATES=$(grep -ohE '`[a-z][a-z0-9]*(_[a-z0-9-]+)+`' "${README}" "${INSTALL_MD}" | tr -d '`' | sort -u)

ALL_ARCH_NAMES=$(jq -r '.[].name' "${ARCHES_JSON}")

_checked=0
for tok in ${CANDIDATES}; do
    _prefix=$(printf '%s' "${tok}" | sed -E 's/^([a-z0-9]+)_.*/\1/')
    case "${PREFIXES}" in
        *" ${_prefix} "*)
            _checked=$((_checked + 1))
            case "
${ALL_ARCH_NAMES}
" in
                *"
${tok}
"*)
                    log_info "OK: C: doc example \`${tok}\` exists in arches.json"
                    ;;
                *)
                    log_fail "C: doc example \`${tok}\` looks like an arch name (prefix '${_prefix}') but is NOT a row in arches.json -- stale/typo'd example?"
                    ;;
            esac
            ;;
        *)
            : # not an arch-family-prefixed token (e.g. extra_args) -- skip
            ;;
    esac
done

assert_eq "C: at least one arch-name example was actually checked (proves the filter isn't vacuous)" \
    "1" "$([ "${_checked}" -ge 1 ] && echo 1 || echo 0)"

harness_finish "tests/apk/docs-arch-coverage.sh"
