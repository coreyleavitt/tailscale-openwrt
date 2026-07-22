#!/bin/sh
# tests/apk/install-arch-block.sh
#
# RFC docs/rfc-apk-arch-coverage.md section 5.5, slice S6: unit-style tests
# for scripts/install.sh's apk_path() infeasible-arch / not-yet-published UX
# and the drift-guard proving scripts/gen-install-arch-block.sh's output
# stays byte-identical to the GENERATED block committed in scripts/install.sh.
# Same INSTALL_SH_NO_MAIN=1 source-and-call-functions-directly pattern as
# tests/apk/install-verify.sh -- no network, no root, no containers.
#
# Six parts:
#   A. Infeasible arch: apk_path() aborts BEFORE touching the feed, with the
#      RFC section 5.5 wording, when /etc/apk/arch names one of arches.json's
#      reason-bearing rows.
#   B. Feasible-but-not-published: a feasible arch that 404s at `apk update`
#      gets a clear "isn't in the feed (not yet published)" message instead
#      of a bare "apk update failed".
#   C. CRLF / multi-line /etc/apk/arch: a trailing \r or a second line must
#      not corrupt the parsed arch (feed URL and infeasible lookup both).
#   D. Drift guard: scripts/gen-install-arch-block.sh regenerated against the
#      real arches.json must be byte-identical to the GENERATED block
#      committed in scripts/install.sh.
#   E. M3 (code-review finding): escape_for_dq neutralizes a `.reason`
#      containing shell metacharacters (`" $ backtick`) that would otherwise
#      break out of the GENERATED echo's double-quoted argument.
#   F. R2 (round-2 code-review finding): a `.reason` containing an embedded
#      newline -- with an injected, case-arm-shaped payload riding it -- must
#      not break row parsing or execute; and families.sh --validate rejects
#      the same fixture at the source (R2a).
#
# Usage:
#   sh tests/apk/install-arch-block.sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
INSTALL_DIR="${REPO_ROOT}/scripts"
ARCHES_JSON="${REPO_ROOT}/arches.json"

# shellcheck source=tests/apk/lib.sh
. "${SCRIPT_DIR}/lib.sh"

require_cmd jq

if [ ! -f "${INSTALL_DIR}/install.sh" ]; then
    echo "FAIL: scripts/install.sh not found" >&2
    exit 1
fi
if [ ! -f "${INSTALL_DIR}/gen-install-arch-block.sh" ]; then
    echo "FAIL: scripts/gen-install-arch-block.sh not found" >&2
    exit 1
fi

WORKDIR=$(mktemp -d)
cleanup() { rm -rf "${WORKDIR}"; }
trap cleanup EXIT

# =====================================================================
# Part A -- infeasible arch: apk_path() aborts before touching the feed
# =====================================================================
echo ""
echo "############################################"
echo "### Part A: infeasible arch -- apk_path() aborts before the feed"
echo "############################################"

mkdir -p "${WORKDIR}/stub-min"
cat > "${WORKDIR}/stub-min/apk" <<'EOF'
#!/bin/sh
echo "apk:$*" >> "${APK_CALL_LOG:-/dev/null}"
exit 1
EOF
chmod +x "${WORKDIR}/stub-min/apk"

APK_CALL_LOG="${WORKDIR}/apk-calls.log"
export APK_CALL_LOG

run_apk_path() {
    # run_apk_path arch_file_content -- sources install.sh in test mode with
    # APK_ARCH_FILE pointed at a fixture holding the given content, and calls
    # apk_path() directly.
    _content="$1"
    _archfile="${WORKDIR}/etc-apk-arch"
    printf '%s' "${_content}" > "${_archfile}"
    (
        INSTALL_SH_NO_MAIN=1
        export INSTALL_SH_NO_MAIN
        SCRIPT_DIR="${INSTALL_DIR}"
        export SCRIPT_DIR
        APK_ARCH_FILE="${_archfile}"
        export APK_ARCH_FILE
        OPKG_INFO_DIR="${WORKDIR}/no-such-opkg-info-dir"
        export OPKG_INFO_DIR
        PATH="${WORKDIR}/stub-min:/usr/bin:/bin"
        export PATH
        . "${INSTALL_DIR}/install.sh"
        apk_path
    )
}

run_apk_path_from_file() {
    # run_apk_path_from_file archfile -- like run_apk_path, but takes an
    # already-written /etc/apk/arch fixture file directly instead of a
    # content string (Part C needs literal \r bytes in the fixture, which a
    # shell function argument can't carry losslessly).
    _archfile="$1"
    (
        INSTALL_SH_NO_MAIN=1
        export INSTALL_SH_NO_MAIN
        SCRIPT_DIR="${INSTALL_DIR}"
        export SCRIPT_DIR
        APK_ARCH_FILE="${_archfile}"
        export APK_ARCH_FILE
        OPKG_INFO_DIR="${WORKDIR}/no-such-opkg-info-dir"
        export OPKG_INFO_DIR
        PATH="${WORKDIR}/stub-min:/usr/bin:/bin"
        export PATH
        . "${INSTALL_DIR}/install.sh"
        apk_path
    )
}

rm -f "${APK_CALL_LOG}"
if OUT=$(run_apk_path 'arm_fa526
' 2>"${WORKDIR}/a1.err"); then
    RC=0
else
    RC=$?
fi
assert_eq "A1 (infeasible arch): apk_path aborts (nonzero exit)" "1" "$([ "${RC}" -ne 0 ] && echo 1 || echo 0)"
assert_contains "A1: error matches the RFC section 5.5 wording" \
    "$(cat "${WORKDIR}/a1.err")" "tailscale can't be built for arm_fa526 (Go has no support: ARMv4 < Go GOARM=5)"
assert_eq "A1: apk was NEVER invoked (never touches the feed)" \
    "" "$(cat "${APK_CALL_LOG}" 2>/dev/null || true)"

# --- A2 (RED-proof control): a feasible arch falls through untouched -----
# (proves A1 isn't vacuous -- the check doesn't reject every arch, only the
# reason-bearing set.)
rm -f "${APK_CALL_LOG}"
if OUT=$(run_apk_path 'aarch64_cortex-a53
' 2>"${WORKDIR}/a2.err"); then
    RC=0
else
    RC=$?
fi
assert_not_contains "A2 (control, feasible arch): never hits the infeasible message" \
    "$(cat "${WORKDIR}/a2.err")" "can't be built for"
assert_contains "A2 (control, feasible arch): proceeds past the check (apk WAS invoked)" \
    "$(cat "${APK_CALL_LOG}" 2>/dev/null || true)" "apk:"

# =====================================================================
# Part B -- feasible-but-not-published: translate apk update/add failure
# =====================================================================
echo ""
echo "############################################"
echo "### Part B: feasible arch not in the feed -- clear message, not a bare failure"
echo "############################################"

require_cmd sha256sum

if [ ! -f "${REPO_ROOT}/apk-signing.pem" ]; then
    echo "FAIL: ${REPO_ROOT}/apk-signing.pem not found (needed to pass the feed-key pin in Part B)" >&2
    exit 1
fi

mkdir -p "${WORKDIR}/stub-b"
cat > "${WORKDIR}/stub-b/apk" <<'EOF'
#!/bin/sh
echo "apk:$*" >> "${APK_CALL_LOG:-/dev/null}"
case "$1 $2 $3" in
    "info -e tailscale")
        exit 1
        ;;
    "info -e ca-bundle")
        exit 0
        ;;
esac
case "$1" in
    update)
        [ "${STUB_APK_UPDATE_MODE:-ok}" = "ok" ] && exit 0
        exit 1
        ;;
    add)
        [ "${STUB_APK_ADD_MODE:-ok}" = "ok" ] && exit 0
        exit 1
        ;;
esac
exit 1
EOF
chmod +x "${WORKDIR}/stub-b/apk"

cat > "${WORKDIR}/stub-b/wget" <<EOF
#!/bin/sh
outfile="\$2"
cp "${REPO_ROOT}/apk-signing.pem" "\$outfile"
exit 0
EOF
chmod +x "${WORKDIR}/stub-b/wget"

run_apk_path_feed() {
    # run_apk_path_feed arch update_mode add_mode -- real (temp-dir-scoped)
    # APK_KEYS_DIR/APK_REPOS_DIR so apk_path() runs genuinely past the feed
    # key verification (real wget stub returns the real, correctly-pinned
    # apk-signing.pem) up to the real apk update/add calls, without ever
    # touching the real /etc/apk.
    _arch="$1"
    _updatemode="$2"
    _addmode="$3"
    _archfile="${WORKDIR}/etc-apk-arch-b"
    printf '%s\n' "${_arch}" > "${_archfile}"
    (
        INSTALL_SH_NO_MAIN=1
        export INSTALL_SH_NO_MAIN
        SCRIPT_DIR="${INSTALL_DIR}"
        export SCRIPT_DIR
        APK_ARCH_FILE="${_archfile}"
        export APK_ARCH_FILE
        APK_KEYS_DIR="${WORKDIR}/apk-keys"
        export APK_KEYS_DIR
        APK_REPOS_DIR="${WORKDIR}/apk-repos"
        export APK_REPOS_DIR
        OPKG_INFO_DIR="${WORKDIR}/no-such-opkg-info-dir"
        export OPKG_INFO_DIR
        STUB_APK_UPDATE_MODE="${_updatemode}"
        export STUB_APK_UPDATE_MODE
        STUB_APK_ADD_MODE="${_addmode}"
        export STUB_APK_ADD_MODE
        PATH="${WORKDIR}/stub-b:/usr/bin:/bin"
        export PATH
        . "${INSTALL_DIR}/install.sh"
        apk_path
    )
}

# --- B1: apk update 404s (arch not published) -> clear message, add never called
rm -rf "${WORKDIR}/apk-keys" "${WORKDIR}/apk-repos"
rm -f "${APK_CALL_LOG}"
if OUT=$(run_apk_path_feed "mips64_octeonplus" "fail" "ok" 2>"${WORKDIR}/b1.err"); then
    RC=0
else
    RC=$?
fi
assert_eq "B1 (apk update 404s): apk_path aborts (nonzero exit)" "1" "$([ "${RC}" -ne 0 ] && echo 1 || echo 0)"
assert_contains "B1: error is the clear 'isn't in the feed' translation" \
    "$(cat "${WORKDIR}/b1.err")" "isn't in the feed"
assert_contains "B1: error names the arch" "$(cat "${WORKDIR}/b1.err")" "mips64_octeonplus"
assert_contains "B1: error mentions not yet published" "$(cat "${WORKDIR}/b1.err")" "not yet published"
assert_not_contains "B1: apk add was never reached (update already failed)" \
    "$(cat "${APK_CALL_LOG}" 2>/dev/null || true)" "apk:add tailscale"

# --- B2: apk update succeeds, apk add tailscale fails (package missing) ----
rm -rf "${WORKDIR}/apk-keys" "${WORKDIR}/apk-repos"
rm -f "${APK_CALL_LOG}"
if OUT=$(run_apk_path_feed "mips64_octeonplus" "ok" "fail" 2>"${WORKDIR}/b2.err"); then
    RC=0
else
    RC=$?
fi
assert_eq "B2 (apk add fails): apk_path aborts (nonzero exit)" "1" "$([ "${RC}" -ne 0 ] && echo 1 || echo 0)"
assert_contains "B2: error is the clear 'isn't in the feed' translation" \
    "$(cat "${WORKDIR}/b2.err")" "isn't in the feed"
assert_contains "B2: error names the arch" "$(cat "${WORKDIR}/b2.err")" "mips64_octeonplus"

# --- B3 (GREEN control): both succeed -> apk_path proceeds past the feed ---
# (proves B1/B2 weren't vacuous -- the stub CAN succeed all the way through)
rm -rf "${WORKDIR}/apk-keys" "${WORKDIR}/apk-repos"
rm -f "${APK_CALL_LOG}"
if OUT=$(run_apk_path_feed "mips64_octeonplus" "ok" "ok" 2>"${WORKDIR}/b3.err"); then
    RC=0
else
    RC=$?
fi
assert_eq "B3 (control): apk_path SUCCEEDS when update+add both succeed" "0" "${RC}"
assert_contains "B3: apk add tailscale WAS called" "$(cat "${APK_CALL_LOG}" 2>/dev/null || true)" "apk:add tailscale"

# =====================================================================
# Part C -- CRLF / multi-line /etc/apk/arch robustness
# =====================================================================
echo ""
echo "############################################"
echo "### Part C: CRLF / multi-line /etc/apk/arch"
echo "############################################"

# --- C1: CRLF-terminated single line, feasible arch -> parsed cleanly,
# reaches the feed (a stray trailing \r would break the feed URL match and
# any infeasible-arch case-statement match alike).
rm -rf "${WORKDIR}/apk-keys" "${WORKDIR}/apk-repos"
rm -f "${APK_CALL_LOG}"
_crlf_archfile="${WORKDIR}/etc-apk-arch-crlf"
printf 'mips64_octeonplus\r\n' > "${_crlf_archfile}"
if OUT=$(
    (
        INSTALL_SH_NO_MAIN=1
        export INSTALL_SH_NO_MAIN
        SCRIPT_DIR="${INSTALL_DIR}"
        export SCRIPT_DIR
        APK_ARCH_FILE="${_crlf_archfile}"
        export APK_ARCH_FILE
        APK_KEYS_DIR="${WORKDIR}/apk-keys"
        export APK_KEYS_DIR
        APK_REPOS_DIR="${WORKDIR}/apk-repos"
        export APK_REPOS_DIR
        OPKG_INFO_DIR="${WORKDIR}/no-such-opkg-info-dir"
        export OPKG_INFO_DIR
        STUB_APK_UPDATE_MODE=ok
        export STUB_APK_UPDATE_MODE
        STUB_APK_ADD_MODE=ok
        export STUB_APK_ADD_MODE
        PATH="${WORKDIR}/stub-b:/usr/bin:/bin"
        export PATH
        . "${INSTALL_DIR}/install.sh"
        apk_path
    ) 2>"${WORKDIR}/c1.err"
); then
    RC=0
else
    RC=$?
fi
assert_eq "C1 (CRLF /etc/apk/arch): apk_path SUCCEEDS (arch parsed cleanly)" "0" "${RC}"
assert_contains "C1: the feed URL uses the arch WITHOUT a trailing CR" \
    "$(cat "${WORKDIR}/c1.err")" "arch mips64_octeonplus (from"
assert_not_contains "C1: no stray carriage return leaks into the logged arch" \
    "$(cat "${WORKDIR}/c1.err")" "$(printf 'mips64_octeonplus\r')"

# --- C2: CRLF-terminated single line, INFEASIBLE arch -> the infeasible
# lookup must also match cleanly (a trailing \r would make the case
# statement fall through to the "feasible" branch instead of rejecting).
rm -f "${APK_CALL_LOG}"
_crlf_infeasible="${WORKDIR}/etc-apk-arch-crlf-infeasible"
printf 'arm_fa526\r\n' > "${_crlf_infeasible}"
if OUT=$(run_apk_path_from_file "${_crlf_infeasible}" 2>"${WORKDIR}/c2.err"); then
    RC=0
else
    RC=$?
fi
assert_eq "C2 (CRLF, infeasible arch): apk_path aborts (nonzero exit)" "1" "$([ "${RC}" -ne 0 ] && echo 1 || echo 0)"
assert_contains "C2: infeasible lookup matches despite the CRLF" \
    "$(cat "${WORKDIR}/c2.err")" "tailscale can't be built for arm_fa526 (Go has no support: ARMv4 < Go GOARM=5)"

# --- C3: multi-line /etc/apk/arch (a device listing more than one
# acceptable arch, e.g. after A5b's own multi-arch trick) -- only the FIRST
# line is this device's own arch; a trailing second line must not corrupt it.
rm -f "${APK_CALL_LOG}"
_multiline_archfile="${WORKDIR}/etc-apk-arch-multiline"
printf 'arm_fa526\nmips64_octeonplus\n' > "${_multiline_archfile}"
if OUT=$(run_apk_path_from_file "${_multiline_archfile}" 2>"${WORKDIR}/c3.err"); then
    RC=0
else
    RC=$?
fi
assert_eq "C3 (multi-line, first line infeasible): apk_path aborts (nonzero exit)" "1" "$([ "${RC}" -ne 0 ] && echo 1 || echo 0)"
assert_contains "C3: infeasible lookup uses the FIRST line only" \
    "$(cat "${WORKDIR}/c3.err")" "tailscale can't be built for arm_fa526 (Go has no support: ARMv4 < Go GOARM=5)"

# =====================================================================
# Part D -- drift guard: the committed GENERATED block in scripts/install.sh
# must be byte-identical to a fresh regeneration from the real arches.json
# =====================================================================
echo ""
echo "############################################"
echo "### Part D: drift guard -- generated block matches arches.json"
echo "############################################"

extract_generated_block() {
    # extract_generated_block file -- prints the text between (and
    # including) the BEGIN/END markers in <file>, or nothing if absent.
    awk '
        /^# >>> GENERATED infeasible-arch block/ { grab=1 }
        grab { print }
        /^# <<< END GENERATED infeasible-arch block/ { grab=0 }
    ' "$1"
}

COMMITTED_BLOCK=$(extract_generated_block "${INSTALL_DIR}/install.sh")
FRESH_BLOCK=$("${INSTALL_DIR}/gen-install-arch-block.sh" "${ARCHES_JSON}")

assert_eq "D1: scripts/install.sh actually contains a GENERATED infeasible-arch block" \
    "1" "$([ -n "${COMMITTED_BLOCK}" ] && echo 1 || echo 0)"
if [ "${COMMITTED_BLOCK}" = "${FRESH_BLOCK}" ]; then
    log_info "OK: D2: committed block is byte-identical to a fresh regeneration from arches.json"
else
    log_fail "D2: committed scripts/install.sh infeasible-arch block has DRIFTED from arches.json -- regenerate with: scripts/gen-install-arch-block.sh"
    printf '%s\n' "${COMMITTED_BLOCK}" > "${WORKDIR}/d2-committed.txt"
    printf '%s\n' "${FRESH_BLOCK}" > "${WORKDIR}/d2-fresh.txt"
    diff "${WORKDIR}/d2-committed.txt" "${WORKDIR}/d2-fresh.txt" >&2 || true
fi

# =====================================================================
# Part E -- M3 (code-review finding): .reason is shell-escaped, not
# spliced verbatim into the GENERATED echo. A reason containing shell
# metacharacters (here, a `"` that would otherwise break out of the
# double-quoted echo argument, chaining extra shell statements) must NOT
# execute; the generated infeasible_reason() must still print it back
# literally.
# =====================================================================
echo ""
echo "############################################"
echo "### Part E: gen-install-arch-block.sh escapes shell-dangerous .reason text (M3)"
echo "############################################"

MALICIOUS_REASON='x"; touch PWNED; echo "y'

jq -n --arg reason "${MALICIOUS_REASON}" '[{
    "name": "evil_arch", "goarch": "", "goarm": "", "gomips": "", "gomips64": "", "go386": "",
    "endian": "little", "float": "soft", "reason": $reason,
    "container_arch": "", "canary": false, "tier": "infeasible", "verify": false,
    "rootfs_target": "", "rootfs_url": "", "rootfs_sha256": ""
}]' > "${WORKDIR}/malicious-arches.json"

GENERATED_BLOCK=$("${INSTALL_DIR}/gen-install-arch-block.sh" "${WORKDIR}/malicious-arches.json")

rm -f "${WORKDIR}/PWNED"
(
    cd "${WORKDIR}"
    eval "${GENERATED_BLOCK}"
    infeasible_reason evil_arch
) >"${WORKDIR}/e1.out" 2>"${WORKDIR}/e1.err"
E1_RC=$?

assert_eq "E1: infeasible_reason(evil_arch) succeeds (finds the case arm)" "0" "${E1_RC}"
assert_eq "E1: the injected 'touch PWNED' did NOT execute" \
    "0" "$([ -e "${WORKDIR}/PWNED" ] && echo 1 || echo 0)"
assert_eq "E1: infeasible_reason prints the malicious reason back LITERALLY, verbatim" \
    "${MALICIOUS_REASON}" "$(cat "${WORKDIR}/e1.out")"

# --- E2: a second flavor -- backtick + \$(...) command substitution, also
# neutralized (proves the fix isn't narrowly tuned to just the `"` case).
E2_REASON='`touch PWNED2` and $(touch PWNED3)'
jq -n --arg reason "${E2_REASON}" '[{
    "name": "evil_arch2", "goarch": "", "goarm": "", "gomips": "", "gomips64": "", "go386": "",
    "endian": "little", "float": "soft", "reason": $reason,
    "container_arch": "", "canary": false, "tier": "infeasible", "verify": false,
    "rootfs_target": "", "rootfs_url": "", "rootfs_sha256": ""
}]' > "${WORKDIR}/malicious-arches-2.json"

GENERATED_BLOCK_2=$("${INSTALL_DIR}/gen-install-arch-block.sh" "${WORKDIR}/malicious-arches-2.json")

rm -f "${WORKDIR}/PWNED2" "${WORKDIR}/PWNED3"
(
    cd "${WORKDIR}"
    eval "${GENERATED_BLOCK_2}"
    infeasible_reason evil_arch2
) >"${WORKDIR}/e2.out" 2>"${WORKDIR}/e2.err"

assert_eq "E2: neither backtick nor \$(...) substitution executed (PWNED2)" \
    "0" "$([ -e "${WORKDIR}/PWNED2" ] && echo 1 || echo 0)"
assert_eq "E2: neither backtick nor \$(...) substitution executed (PWNED3)" \
    "0" "$([ -e "${WORKDIR}/PWNED3" ] && echo 1 || echo 0)"
assert_eq "E2: infeasible_reason prints the malicious reason back LITERALLY, verbatim" \
    "${E2_REASON}" "$(cat "${WORKDIR}/e2.out")"

# NOTE: Part D above already proves the escaping change is a no-op for the
# real, current reason set (byte-identical committed-vs-fresh comparison),
# so M3's fix needs no companion scripts/install.sh regeneration.

# =====================================================================
# Part F -- R2 (round-2 code-review finding, HIGH-adjacent): a `.reason`
# containing an EMBEDDED NEWLINE must not break row parsing and splice raw,
# unescaped text into the GENERATED block. escape_for_dq alone (Part E)
# only ever protects against `\ " $ backtick`, not newlines -- the old
# `jq -r '"\(.name)\t\(.reason)"'` extraction decoded a JSON-escaped `\n`
# back into a literal newline byte, which the `while IFS=<tab> read` row
# loop then treated as an extra row boundary. gen-install-arch-block.sh now
# iterates rows via `jq -c` (keeping JSON string escaping intact, so an
# embedded newline can never manifest as a raw delimiter) -- this part
# proves that fix against a payload shaped to actually exploit the OLD
# bug: an embedded newline immediately followed by text that looks like it
# closes the current case arm and opens a new, executable one.
# =====================================================================
echo ""
echo "############################################"
echo "### Part F: gen-install-arch-block.sh survives an embedded-newline injection in .reason (R2)"
echo "############################################"

MULTILINE_REASON="safe start
evil_arch3) touch PWNED_NL ;;
        *)"

jq -n --arg reason "${MULTILINE_REASON}" '[{
    "name": "evil_arch3", "goarch": "", "goarm": "", "gomips": "", "gomips64": "", "go386": "",
    "endian": "little", "float": "soft", "reason": $reason,
    "container_arch": "", "canary": false, "tier": "infeasible", "native_verify": false,
    "rootfs_target": "", "rootfs_url": "", "rootfs_sha256": ""
}]' > "${WORKDIR}/malicious-arches-nl.json"

# Precondition: the fixture really carries an embedded newline, so this
# isn't a vacuous test of the (already-covered) quote/backtick cases.
assert_eq "F0 precondition: the fixture's reason contains a newline" \
    "true" "$(jq -r '.[0].reason | test("\n")' "${WORKDIR}/malicious-arches-nl.json")"

GENERATED_BLOCK_NL=$("${INSTALL_DIR}/gen-install-arch-block.sh" "${WORKDIR}/malicious-arches-nl.json")

rm -f "${WORKDIR}/PWNED_NL"
(
    cd "${WORKDIR}"
    eval "${GENERATED_BLOCK_NL}"
    infeasible_reason evil_arch3
) >"${WORKDIR}/f1.out" 2>"${WORKDIR}/f1.err"
F1_RC=$?

assert_eq "F1: infeasible_reason(evil_arch3) succeeds (finds the case arm)" "0" "${F1_RC}"
assert_eq "F1: the injected 'touch PWNED_NL' did NOT execute" \
    "0" "$([ -e "${WORKDIR}/PWNED_NL" ] && echo 1 || echo 0)"
assert_eq "F1: infeasible_reason prints the malicious multi-line reason back LITERALLY, verbatim" \
    "${MULTILINE_REASON}" "$(cat "${WORKDIR}/f1.out")"

echo ""
echo "=== Part F: families.sh --validate rejects the SAME embedded-newline fixture (R2a, at the source) ==="

set +e
sh "${INSTALL_DIR}/families.sh" --validate "${WORKDIR}/malicious-arches-nl.json" >"${WORKDIR}/f2.out" 2>&1
F2_RC=$?
set -e

if [ "${F2_RC}" -ne 0 ]; then
    log_info "OK: families.sh --validate rejects a .reason with an embedded newline"
else
    log_fail "families.sh --validate ACCEPTED a .reason with an embedded, injection-shaped newline:
$(cat "${WORKDIR}/f2.out")"
fi

echo ""

harness_finish "tests/apk/install-arch-block.sh"
