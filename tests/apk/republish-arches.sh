#!/bin/sh
# tests/apk/republish-arches.sh
#
# §5.8 Rollback allowlist (RFC docs/rfc-apk-arch-coverage.md, round-2
# B-SEV2): `republish-feed`'s assemble+verify loops used to hard-code
# `sh scripts/families.sh --tier-arches core arches.json` -- the ONLY way
# to roll back (or re-publish an older release for) a single bad
# `extended` arch was a full 30-arch republish, which would ALSO
# force-downgrade the healthy 4 `core` arches past the C3 monotonicity
# guard (the exact hazard the allowlist input exists to prevent).
#
# This exercises `scripts/families.sh --resolve-republish-arches` --
# the resolve+validate seam for the new `republish_arches`
# workflow_dispatch input -- hermetically (no docker/qemu/live Actions
# run needed), against the real arches.json:
#
#   1. empty/unset/whitespace/comma-only allowlist -> the tier=="core" set,
#      UNCHANGED (an existing core republish/rollback must behave exactly
#      as before this input existed -- behavior-preserving default).
#   2. a single valid `extended` arch -> exactly that one arch.
#   3. a valid multi-arch subset (comma- and/or space-separated,
#      duplicates collapsed) -> exactly those arches, sorted.
#   4. an explicit `core` arch is also a legal target (feasible ==
#      core UNION extended, not "extended only").
#   5. an unknown/typo'd name -> non-zero exit, naming the bad token,
#      NOTHING useful on stdout (no partial/wrong set).
#   6. a real arch whose OWN tier is "infeasible" (e.g. powerpc_8548) ->
#      same hard-fail, not silently accepted.
#   7. a mix of one valid + one invalid name in a single call -> the
#      WHOLE call fails (never partial success -- "never silently
#      publish nothing or the wrong set").
#   8. injection-shaped names (the same fixture set families.sh
#      --validate's M1 section already guards `.name` against) ->
#      rejected up front, by shape, before any membership check --
#      this resolver's own stdout is what build-tailscale.yaml's
#      republish-feed loops splice into a shell `for arch in ...`, so it
#      must never echo back anything shell-dangerous.
#   9. build-tailscale.yaml wiring: the `republish_arches` input exists,
#      both republish-feed loops route through
#      `--resolve-republish-arches` (not a re-hardcoded `--tier-arches
#      core`), and the resolved set is captured into a real shell
#      variable/file BEFORE the `for` loop -- never spliced directly as
#      `for arch in $(...)`, which would silently swallow a resolver
#      failure under `set -e` (a real footgun: command-substitution
#      failure inside a `for` word list does not trigger `set -e`).
#
# Usage: sh tests/apk/republish-arches.sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
FAMILIES_SH="${REPO_ROOT}/scripts/families.sh"
ARCHES_JSON="${REPO_ROOT}/arches.json"
WORKFLOW="${REPO_ROOT}/.github/workflows/build-tailscale.yaml"

# shellcheck source=tests/apk/lib.sh
. "${SCRIPT_DIR}/lib.sh"

require_cmd jq

if [ ! -f "${FAMILIES_SH}" ]; then
    log_fail "scripts/families.sh not found at ${FAMILIES_SH}"
    harness_finish "tests/apk/republish-arches.sh"
    exit "${FAIL}"
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "${WORKDIR}"' EXIT

EXPECTED_CORE='aarch64_cortex-a53
arm_cortex-a7
mips_24kc
mipsel_24kc'

# --- 1. empty/unset/whitespace/comma-only -> unchanged core default -------

echo "=== 1. empty allowlist -> exactly the 4 core arches (behavior-preserving default) ==="

RESOLVED_EMPTY=$("${FAMILIES_SH}" --resolve-republish-arches "" "${ARCHES_JSON}")
assert_eq "empty allowlist resolves to exactly the 4 historical core arches" \
    "${EXPECTED_CORE}" "${RESOLVED_EMPTY}"

TIER_CORE=$("${FAMILIES_SH}" --tier-arches core "${ARCHES_JSON}")
assert_eq "empty-allowlist resolution == families.sh --tier-arches core (same accessor, not re-derived)" \
    "${TIER_CORE}" "${RESOLVED_EMPTY}"

echo
echo "=== 1b. whitespace-only allowlist -> same default ==="

RESOLVED_WS=$("${FAMILIES_SH}" --resolve-republish-arches "   " "${ARCHES_JSON}")
assert_eq "whitespace-only allowlist resolves to the core default" \
    "${EXPECTED_CORE}" "${RESOLVED_WS}"

echo
echo "=== 1c. comma-only allowlist -> same default ==="

RESOLVED_COMMAS=$("${FAMILIES_SH}" --resolve-republish-arches ",, ," "${ARCHES_JSON}")
assert_eq "comma-only allowlist resolves to the core default" \
    "${EXPECTED_CORE}" "${RESOLVED_COMMAS}"

echo

# --- 2. a single valid extended arch ---------------------------------------

echo "=== 2. a single valid extended arch -> exactly that arch ==="

RISCV_TIER=$(jq -r '.[] | select(.name == "riscv64_generic") | .tier' "${ARCHES_JSON}")
assert_eq "precondition: riscv64_generic is tier==extended in the real table" "extended" "${RISCV_TIER}"

RESOLVED_RISCV=$("${FAMILIES_SH}" --resolve-republish-arches "riscv64_generic" "${ARCHES_JSON}")
assert_eq "a single extended arch resolves to exactly that arch" "riscv64_generic" "${RESOLVED_RISCV}"

echo

# --- 3. a valid multi-arch subset, both separators, dedup -------------------

echo "=== 3. multi-arch subset (comma-separated) -> exactly those, sorted ==="

RESOLVED_MULTI_COMMA=$("${FAMILIES_SH}" --resolve-republish-arches "riscv64_generic,aarch64_generic" "${ARCHES_JSON}")
EXPECTED_MULTI='aarch64_generic
riscv64_generic'
assert_eq "comma-separated subset resolves to exactly those 2 arches, sorted" \
    "${EXPECTED_MULTI}" "${RESOLVED_MULTI_COMMA}"

echo
echo "=== 3b. multi-arch subset (space-separated) -> the SAME resolved set ==="

RESOLVED_MULTI_SPACE=$("${FAMILIES_SH}" --resolve-republish-arches "riscv64_generic aarch64_generic" "${ARCHES_JSON}")
assert_eq "space-separated subset resolves identically to the comma-separated one" \
    "${RESOLVED_MULTI_COMMA}" "${RESOLVED_MULTI_SPACE}"

echo
echo "=== 3c. duplicate names collapse to one entry ==="

RESOLVED_DUP=$("${FAMILIES_SH}" --resolve-republish-arches "riscv64_generic, riscv64_generic" "${ARCHES_JSON}")
assert_eq "a duplicated name is de-duplicated" "riscv64_generic" "${RESOLVED_DUP}"

echo

# --- 4. an explicit core arch is also legal (feasible = core UNION extended)

echo "=== 4. an explicit tier==core name is a legal target too (not extended-only) ==="

RESOLVED_CORE_EXPLICIT=$("${FAMILIES_SH}" --resolve-republish-arches "aarch64_cortex-a53" "${ARCHES_JSON}")
assert_eq "an explicitly-named core arch resolves to exactly itself" \
    "aarch64_cortex-a53" "${RESOLVED_CORE_EXPLICIT}"

echo

# --- 5. unknown/typo'd name hard-fails ---------------------------------------

echo "=== 5. an unknown arch name hard-fails, naming the bad token ==="

set +e
BOGUS_OUT=$("${FAMILIES_SH}" --resolve-republish-arches "bogus_arch" "${ARCHES_JSON}" 2>"${WORKDIR}/bogus.err")
BOGUS_RC=$?
set -e
BOGUS_ERR=$(cat "${WORKDIR}/bogus.err")

if [ "${BOGUS_RC}" -eq 0 ]; then
    log_fail "an unknown arch name 'bogus_arch' should hard-fail (exit 0, stdout: '${BOGUS_OUT}')"
else
    log_info "OK: an unknown arch name exits non-zero (${BOGUS_RC})"
fi
assert_eq "an unknown arch name prints NOTHING to stdout" "" "${BOGUS_OUT}"
assert_contains "stderr names the offending token" "${BOGUS_ERR}" "bogus_arch"

echo

# --- 6. a real but infeasible-tier arch hard-fails ---------------------------

echo "=== 6. a real, but infeasible-tier, arch name hard-fails ==="

PPC_TIER=$(jq -r '.[] | select(.name == "powerpc_8548") | .tier' "${ARCHES_JSON}")
assert_eq "precondition: powerpc_8548 is tier==infeasible in the real table" "infeasible" "${PPC_TIER}"

set +e
PPC_OUT=$("${FAMILIES_SH}" --resolve-republish-arches "powerpc_8548" "${ARCHES_JSON}" 2>"${WORKDIR}/ppc.err")
PPC_RC=$?
set -e
PPC_ERR=$(cat "${WORKDIR}/ppc.err")

if [ "${PPC_RC}" -eq 0 ]; then
    log_fail "infeasible-tier arch 'powerpc_8548' should hard-fail (exit 0, stdout: '${PPC_OUT}')"
else
    log_info "OK: an infeasible-tier arch name exits non-zero (${PPC_RC})"
fi
assert_eq "an infeasible-tier arch name prints NOTHING to stdout" "" "${PPC_OUT}"
assert_contains "stderr names the offending infeasible-tier token" "${PPC_ERR}" "powerpc_8548"

echo

# --- 7. one valid + one invalid in the same call -> the WHOLE call fails ---

echo "=== 7. one valid + one invalid name in the same allowlist -> the whole call fails, no partial output ==="

set +e
MIXED_OUT=$("${FAMILIES_SH}" --resolve-republish-arches "riscv64_generic,bogus_arch" "${ARCHES_JSON}" 2>"${WORKDIR}/mixed.err")
MIXED_RC=$?
set -e

if [ "${MIXED_RC}" -eq 0 ]; then
    log_fail "a mixed valid+invalid allowlist should hard-fail (exit 0, stdout: '${MIXED_OUT}')"
else
    log_info "OK: a mixed valid+invalid allowlist exits non-zero (${MIXED_RC})"
fi
assert_eq "a mixed valid+invalid allowlist never partially succeeds (no 'riscv64_generic'-only output)" "" "${MIXED_OUT}"

echo

# --- 8. injection-shaped names are rejected up front, by shape -------------

echo "=== 8. injection-shaped names are rejected (never echoed to stdout) ==="

# Same fixture set families.sh --validate's M1 section guards `.name`
# against -- this resolver's stdout feeds the exact same class of
# downstream shell `for` splice (build-tailscale.yaml's republish-feed
# loops), so it must reject these just as hard.
INJECTION_NAMES='evil; rm -rf /
evil name with spaces
evil"quote
evil$(touch PWNED)
evil`touch PWNED`
UPPERCASE_not_allowed
/etc/passwd
-leading-dash'

_old_ifs="${IFS}"
IFS='
'
for bad_name in ${INJECTION_NAMES}; do
    IFS="${_old_ifs}"
    [ -n "${bad_name}" ] || continue

    set +e
    BAD_OUT=$("${FAMILIES_SH}" --resolve-republish-arches "${bad_name}" "${ARCHES_JSON}" 2>"${WORKDIR}/bad-name.err")
    BAD_RC=$?
    set -e

    if [ "${BAD_RC}" -ne 0 ]; then
        log_info "OK: injection-shaped name '${bad_name}' is rejected (exit ${BAD_RC})"
    else
        log_fail "injection-shaped name '${bad_name}' was ACCEPTED (stdout: '${BAD_OUT}')"
    fi
    assert_eq "injection-shaped name '${bad_name}' prints nothing to stdout" "" "${BAD_OUT}"
    IFS='
'
done
IFS="${_old_ifs}"

echo

# --- 9. build-tailscale.yaml wiring -----------------------------------------

echo "=== 9. build-tailscale.yaml: republish_arches input exists ==="

if grep -q 'republish_arches:' "${WORKFLOW}"; then
    log_info "OK: build-tailscale.yaml declares a republish_arches workflow_dispatch input"
else
    log_fail "build-tailscale.yaml is missing a republish_arches workflow_dispatch input"
fi

echo
echo "=== 9b. both republish-feed loops route through --resolve-republish-arches ==="

RESOLVE_CALL_COUNT=$(grep -c -- '--resolve-republish-arches' "${WORKFLOW}" || true)
if [ "${RESOLVE_CALL_COUNT}" -ge 2 ]; then
    log_info "OK: --resolve-republish-arches is referenced at least twice in build-tailscale.yaml (${RESOLVE_CALL_COUNT} times)"
else
    log_fail "expected --resolve-republish-arches to be referenced at least twice (assemble loop + verify loop) in build-tailscale.yaml, found ${RESOLVE_CALL_COUNT}"
fi

echo
echo "=== 9c. republish-feed's two loops no longer hardcode --tier-arches core ==="

# Scope the drift-guard to the republish-feed job only (--tier-arches core
# legitimately still appears elsewhere, e.g. select-matrix.sh's own
# --ipk-arches call path, which is out of scope for this change).
# republish-feed is the LAST job in the file (confirmed against the job
# list below), so "from its header to EOF" is exactly its body -- no
# next-job boundary to find.
REPUBLISH_JOB=$(sed -n '/^  republish-feed:/,$p' "${WORKFLOW}")
if ! grep -q '^  republish-feed:$' "${WORKFLOW}"; then
    log_fail "sanity: republish-feed job header not found in build-tailscale.yaml -- job scoping below would silently be empty"
fi
HARDCODED_CORE_IN_LOOPS=$(printf '%s\n' "${REPUBLISH_JOB}" | grep -c -- '--tier-arches core' || true)
assert_eq "republish-feed job no longer hardcodes --tier-arches core in its loops" "0" "${HARDCODED_CORE_IN_LOOPS}"

echo
echo "=== 9d. the resolved arch set is captured into a real shell value BEFORE the for loop (never 'for arch in \$(...)' directly) ==="

# A resolver failure inside a bare `for arch in $(cmd)` word-list
# expansion does NOT trigger `set -e` (a well-known POSIX/bash/dash
# footgun: command-substitution failure is only checked when the
# substitution is itself a simple command, e.g. `x=$(cmd)`, not when
# it's nested inside another command's word expansion) -- so the
# resolver's own hard-fail must be checked via an assignment or a file
# read, never spliced directly into the for-loop's word list, or a bad
# allowlist would silently degrade to a zero-arch loop instead of failing
# the job.
DIRECT_SPLICE=$(printf '%s\n' "${REPUBLISH_JOB}" | grep -c -- 'for arch in \$(sh scripts/families.sh --resolve-republish-arches' || true)
assert_eq "the resolver call is never spliced directly into 'for arch in \$(...)' (would silently swallow set -e)" "0" "${DIRECT_SPLICE}"

echo

harness_finish "tests/apk/republish-arches.sh"
