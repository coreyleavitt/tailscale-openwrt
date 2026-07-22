#!/bin/sh
# tests/apk/arch-drift.sh
#
# Slice S9 (RFC docs/rfc-apk-arch-coverage.md §5.7 -- the final slice): unit
# tests for scripts/detect-arch-drift.sh, mirroring
# tests/apk/failure-isolation.sh's Part 4 idiom for detect-apk-drift.sh
# (build local fixtures, run the script against them, assert on the exit
# code + output). Hermetic -- no network, no docker; the live OpenWrt index
# is injected as a local HTML fixture file, never fetched here.
#
# Covers:
#   1. A fixture whose arch set == arches.json's full name set (feasible +
#      infeasible) -> exit 0, "no drift", and neither an ADDITIONS nor a
#      REMOVALS section is printed.
#   2. A fixture with one EXTRA arch not in arches.json -> exit 1, that arch
#      named under ADDITIONS.
#   3. A fixture MISSING one arches.json name -> exit 1, that name named
#      under REMOVALS, and the message references the decommission runbook
#      (docs/MAINTAINING.md#arch-decommission-runbook).
#   4. Infeasible arches (arm_fa526, armeb_xscale, powerpc_8548,
#      powerpc_464fp, powerpc64_e5500 -- reason != null rows, real OpenWrt
#      arches Go can't target) are present in the exit-0 fixture from case 1
#      and explicitly asserted to NOT appear in any drift output -- proves
#      the diff is against arches.json's FULL name set, not just the
#      feasible subset.
#   5. A missing source file, and a fetched-but-garbage/unparseable source,
#      both -> exit 2 (hard error), distinct from exit 0 (case 1) and exit 1
#      (cases 2/3).
#   6. The three exit codes (0/1/2) are pairwise distinct across all cases
#      above -- the property the calling workflow's warn-only branching
#      (exit 1 warns without failing, exit 2 warns as "undetermined" without
#      failing, exit 0 logs clean) depends on.
#
# Usage: sh tests/apk/arch-drift.sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
DETECT_ARCH_DRIFT="${REPO_ROOT}/scripts/detect-arch-drift.sh"
ARCHES_JSON="${REPO_ROOT}/arches.json"

# shellcheck source=tests/apk/lib.sh
. "${SCRIPT_DIR}/lib.sh"

require_cmd jq

[ -f "${DETECT_ARCH_DRIFT}" ] || { echo "FAIL: ${DETECT_ARCH_DRIFT} not found" >&2; exit 1; }

WORKDIR=$(mktemp -d)
cleanup() { rm -rf "${WORKDIR}"; }
trap cleanup EXIT

# mk_index dest_file name... -- writes a minimal OpenWrt dir-index.cgi-shaped
# HTML fixture whose table rows are exactly the given arch names, one
# `<a href="NAME/">NAME</a>/` entry each. Includes the same breadcrumb-link
# noise the real page has (`<a href="/releases/">releases</a> /`, spaced
# before its separating slash) as a RED-proof control that the parser's
# "href text immediately followed by /" rule really does exclude breadcrumbs
# rather than accidentally matching everything.
mk_index() {
    _dest="$1"; shift
    {
        echo '<html><body>'
        echo '<h1><a href="/"><em>(root)</em></a> / <a href="/releases/">releases</a> / <a href="/releases/25.12.0/">25.12.0</a> / <a href="/releases/25.12.0/packages/">packages</a> / </h1>'
        echo '<table>'
        for _name in "$@"; do
            echo "  <tr><td class=\"n\"><a href=\"${_name}/\">${_name}</a>/</td><td class=\"s\">-</td><td class=\"d\">-</td></tr>"
        done
        echo '</table></body></html>'
    } > "${_dest}"
}

ALL_TRACKED=$(jq -r '.[].name' "${ARCHES_JSON}" | sort -u)

drift_rc() {
    _src="$1"
    if sh "${DETECT_ARCH_DRIFT}" "${_src}" "${ARCHES_JSON}" >"${WORKDIR}/out.log" 2>&1; then
        echo 0
    else
        echo "$?"
    fi
}

# ===========================================================================
# 1. exact match -> no drift (exit 0), no ADDITIONS/REMOVALS sections
# ===========================================================================
echo "=== 1. exact match: no drift ==="
# shellcheck disable=SC2086
mk_index "${WORKDIR}/idx-exact.html" ${ALL_TRACKED}

RC_EXACT=$(drift_rc "${WORKDIR}/idx-exact.html")
assert_eq "exact arch set match: no drift (exit 0)" "0" "${RC_EXACT}"
assert_contains "no-drift output says so" "$(cat "${WORKDIR}/out.log")" "NO DRIFT"
assert_not_contains "no-drift output has no ADDITIONS section" "$(cat "${WORKDIR}/out.log")" "ADDITIONS"
assert_not_contains "no-drift output has no REMOVALS section" "$(cat "${WORKDIR}/out.log")" "REMOVALS"

# ===========================================================================
# 4. infeasible arches present in the exact-match fixture do NOT register as
#    drift -- explicit check that none of the 5 infeasible-but-tracked names
#    appear anywhere in a drift section (there IS no drift section here, but
#    assert on the raw names too so this survives a refactor of the message
#    wording).
# ===========================================================================
echo "=== 4. infeasible arches do not register as drift ==="
for _infeasible in arm_fa526 armeb_xscale powerpc_8548 powerpc_464fp powerpc64_e5500; do
    assert_contains "infeasible arch '${_infeasible}' is present in the exact-match fixture (sanity)" \
        "$(cat "${WORKDIR}/idx-exact.html")" "${_infeasible}"
done
assert_eq "exact match (incl. infeasible arches) still exits 0" "0" "${RC_EXACT}"

# ===========================================================================
# 2. one extra arch not in arches.json -> drift, reported as an addition
# ===========================================================================
echo "=== 2. addition: extra arch in the live index ==="
# shellcheck disable=SC2086
mk_index "${WORKDIR}/idx-addition.html" ${ALL_TRACKED} riscv32_newchip

RC_ADD=$(drift_rc "${WORKDIR}/idx-addition.html")
assert_eq "extra live arch: drift (exit 1)" "1" "${RC_ADD}"
assert_contains "addition output names ADDITIONS section" "$(cat "${WORKDIR}/out.log")" "ADDITIONS"
assert_contains "addition output names the new arch" "$(cat "${WORKDIR}/out.log")" "riscv32_newchip"
assert_not_contains "addition-only output has no REMOVALS section" "$(cat "${WORKDIR}/out.log")" "REMOVALS"

# ===========================================================================
# 3. missing one arches.json name -> drift, reported as a removal,
#    references the decommission runbook
# ===========================================================================
echo "=== 3. removal: arches.json name missing from the live index ==="
WITHOUT_X86_64=$(printf '%s\n' "${ALL_TRACKED}" | grep -v '^x86_64$')
# shellcheck disable=SC2086
mk_index "${WORKDIR}/idx-removal.html" ${WITHOUT_X86_64}

RC_REM=$(drift_rc "${WORKDIR}/idx-removal.html")
assert_eq "missing tracked arch: drift (exit 1)" "1" "${RC_REM}"
assert_contains "removal output names REMOVALS section" "$(cat "${WORKDIR}/out.log")" "REMOVALS"
assert_contains "removal output names the missing arch" "$(cat "${WORKDIR}/out.log")" "x86_64"
assert_not_contains "removal-only output has no ADDITIONS section" "$(cat "${WORKDIR}/out.log")" "ADDITIONS"
assert_contains "removal output cross-references the decommission runbook" \
    "$(cat "${WORKDIR}/out.log")" "MAINTAINING.md#arch-decommission-runbook"

# ===========================================================================
# 5. missing/garbage/unfetchable source -> hard error (exit 2), distinct
#    from both exit 0 and exit 1
# ===========================================================================
echo "=== 5. hard error: missing / garbage source ==="
RC_MISSING=$(drift_rc "${WORKDIR}/does-not-exist.html")
assert_eq "nonexistent source file: hard error (exit 2)" "2" "${RC_MISSING}"

echo "this is not an html directory listing at all" > "${WORKDIR}/idx-garbage.html"
RC_GARBAGE=$(drift_rc "${WORKDIR}/idx-garbage.html")
assert_eq "garbage/unparseable source: hard error (exit 2)" "2" "${RC_GARBAGE}"
assert_contains "hard-error output is distinguishable from a drift/in-sync result" \
    "$(cat "${WORKDIR}/out.log")" "ERROR"

RC_UNREACHABLE=$(drift_rc "http://127.0.0.1:1/packages/")
assert_eq "unreachable URL (hard network error): hard error (exit 2)" "2" "${RC_UNREACHABLE}"

# ===========================================================================
# 6. the three exit codes are pairwise distinct across the above cases --
#    the property check-arch-drift.yaml's warn-only branching depends on.
# ===========================================================================
echo "=== 6. exit-code distinctness ==="
assert_eq "0 (in-sync) != 1 (drift)" "1" "$([ "${RC_EXACT}" != "${RC_ADD}" ] && echo 1 || echo 0)"
assert_eq "0 (in-sync) != 2 (hard error)" "1" "$([ "${RC_EXACT}" != "${RC_MISSING}" ] && echo 1 || echo 0)"
assert_eq "1 (drift) != 2 (hard error)" "1" "$([ "${RC_ADD}" != "${RC_MISSING}" ] && echo 1 || echo 0)"

harness_finish "tests/apk/arch-drift.sh"
