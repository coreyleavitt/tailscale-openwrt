#!/bin/sh
# tests/apk/install-verify.sh
#
# Unit-style tests (RFC docs/rfc-apk-builds.md, code-review findings
# H1/H2/M9/L9 -- see docs/rfc-apk-builds.handoff.md's findings table) for
# behavior added/changed directly in scripts/install.sh and
# scripts/install-glinet.sh. Deliberately NOT the heavy docker/qemu style
# of tests/apk/install-dispatch.sh's Part 4 -- everything here uses the
# same INSTALL_SH_NO_MAIN=1 (and the new, analogous
# INSTALL_GLINET_SH_NO_MAIN=1) source-and-call-functions-directly pattern,
# with PATH-prepended stub binaries standing in for wget/usign/opkg/openssl
# where needed. No network access, no root, no containers.
#
# Nine parts:
#
#   A. H1 -- ipk_path() must download+verify a usign signature (via the
#      pinned repo-root `signing.pub`, key-id 260114ce974e57e5) BEFORE ever
#      calling `opkg install`, and must abort (never install) if the
#      signature is missing or fails verification.
#   B. H2 -- apk_path()'s pinned-fingerprint check (extracted as
#      apk_feed_key_fingerprint(), matching scripts/adb-sign.py's key_id()
#      derivation byte-for-byte) rejects a fetched feed key whose
#      fingerprint doesn't match the constant baked into install.sh, and
#      accepts the real committed apk-signing.pem (key-id
#      5079908ab7ada08cbe4308cdf40a904f).
#   C. M9 -- -y/AUTO_YES now propagates all the way to the glinet path:
#      install.sh's glinet_path() forwards -y (not just -v), and the
#      shared should_reinstall()/AUTO_YES convention (promoted into
#      lib-install.sh) genuinely skips the confirmation prompt rather than
#      just relying on a default answer.
#   D. L9 -- install-glinet.sh's extracted tailscaled_current_version()
#      returns "unknown" (never empty) for a missing/non-executable/broken
#      tailscaled binary.
#
# Round-3 review findings (docs/rfc-apk-builds.handoff.md):
#   E/F. FIX1 -- should_reinstall()'s prompt default is "n" (never "y"): a
#      non-interactive re-run without -y/AUTO_YES (cron, or any session
#      where /dev/tty can't be opened -- prompt_confirm treats that the
#      same as an empty response) must be a safe NO-OP, never an unattended
#      reinstall/service restart. E covers should_reinstall() directly; F
#      covers the actual ipk_path()/apk_path() call sites end to end.
#   G. FIX3 -- ipk_path() binds a usign-verified .ipk to the REQUESTED
#      identity (version + arch) via its own control metadata
#      (ipk_control_field(), reading `opkg info <file>`), rejecting a
#      validly-signed but stale/wrong-identity package instead of trusting
#      "usign -V succeeded" alone.
#   H. FIX2 -- the shared sha256_verify() primitive (lib-install.sh),
#      promoted out of two independently-implemented "compute sha256,
#      compare, fail closed" checks (install.sh's apk feed-key pin,
#      install-glinet.sh's binary check).
#   I. FIX4 -- install-glinet.sh's download_binary() now verifies a usign
#      signature (SHA256SUMS.sig, pinned TAILSCALE_USIGN_PUBKEY -- shared
#      with the ipk path via lib-install.sh) over SHA256SUMS BEFORE trusting
#      its hashes to check the raw tailscaled binary, closing the
#      same-untrusted-host-verifies-itself gap.
#
# Usage:
#   sh tests/apk/install-verify.sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
INSTALL_DIR="${REPO_ROOT}/scripts"

# shellcheck source=tests/apk/lib.sh
. "${SCRIPT_DIR}/lib.sh"

require_cmd openssl

if [ ! -f "${INSTALL_DIR}/install.sh" ]; then
    echo "FAIL: scripts/install.sh not found" >&2
    exit 1
fi
if [ ! -f "${INSTALL_DIR}/install-glinet.sh" ]; then
    echo "FAIL: scripts/install-glinet.sh not found" >&2
    exit 1
fi

WORKDIR=$(mktemp -d)
cleanup() { rm -rf "${WORKDIR}"; }
trap cleanup EXIT

# =====================================================================
# Part A -- H1: ipk_path() usign signature verification
# =====================================================================
echo ""
echo "############################################"
echo "### Part A: H1 -- ipk_path() usign signature verification"
echo "############################################"

# The pinned pubkey install.sh bakes in must be byte-for-byte the
# git-tracked repo-root signing.pub (proves the constant wasn't invented --
# see the H1 investigation: signing.pub's key-id 260114ce974e57e5 matches
# what CI's /sign/usign already signs with).
assert_eq "H1: repo-root signing.pub is git-tracked (the pinned pubkey source)" \
    "signing.pub" "$(git -C "${REPO_ROOT}" ls-files -- signing.pub)"
PINNED_PUBKEY_LINE=$(sed -n '2p' "${REPO_ROOT}/signing.pub")
# Round-3 FIX4: TAILSCALE_USIGN_PUBKEY was promoted out of install.sh into
# the single shared scripts/lib-install.sh (install-glinet.sh's SHA256SUMS.sig
# check needs the SAME pinned key) -- so the byte-for-byte-matches-signing.pub
# assertion now targets lib-install.sh, the actual source of truth, not
# install.sh's own bytes (which no longer contain the constant at all, only
# a reference to it -- see Part I's I0 for that structural check).
assert_contains "lib-install.sh bakes in the SAME pubkey content as repo-root signing.pub" \
    "$(cat "${INSTALL_DIR}/lib-install.sh")" "${PINNED_PUBKEY_LINE}"

mkdir -p "${WORKDIR}/stub-full" "${WORKDIR}/stub-nousign"

cat > "${WORKDIR}/stub-full/uname" <<'EOF'
#!/bin/sh
echo aarch64
EOF

cat > "${WORKDIR}/stub-full/pgrep" <<'EOF'
#!/bin/sh
# Always "found" -- keeps poll_for_service from actually sleeping/polling
# on the success path.
exit 0
EOF

cat > "${WORKDIR}/stub-full/opkg" <<'EOF'
#!/bin/sh
case "$1" in
    list-installed)
        # STUB_OPKG_INSTALLED=yes -> report tailscale already installed
        # (FIX1's reinstall-gate tests); default/unset -> "not installed"
        # (Part A's own already-installed check must see this as a
        # fresh install).
        if [ "${STUB_OPKG_INSTALLED:-no}" = "yes" ]; then
            echo "tailscale - 1.0.0"
        fi
        exit 0
        ;;
    install)
        echo "install:$2" >> "${OPKG_INSTALL_LOG:-/dev/null}"
        echo "opkg: installing $2 (stub)"
        exit 0
        ;;
    info)
        # FIX3: ipk_control_field()'s own call convention -- `opkg info
        # <local .ipk path>`. STUB_OPKG_INFO_MODE=fail simulates opkg
        # failing outright (corrupt/unparseable file); otherwise prints a
        # control stanza with the requested version/arch by default (so
        # every OTHER test in this file that runs ipk_path() to a
        # successful install isn't broken by this addition), overridable
        # per-test via STUB_OPKG_INFO_VERSION/STUB_OPKG_INFO_ARCH.
        if [ "${STUB_OPKG_INFO_MODE:-ok}" = "fail" ]; then
            exit 1
        fi
        printf 'Package: tailscale\n'
        printf 'Version: %s\n' "${STUB_OPKG_INFO_VERSION:-9.99.9-1}"
        printf 'Architecture: %s\n' "${STUB_OPKG_INFO_ARCH:-aarch64_cortex-a53}"
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
EOF

cat > "${WORKDIR}/stub-full/wget" <<'EOF'
#!/bin/sh
# ipk_path()'s own calling convention: wget -qO <outfile> <url>
outfile="$2"
url="$3"
case "$url" in
    *.ipk.sig)
        if [ "${STUB_SIG_MODE:-ok}" = "missing" ]; then
            exit 1
        fi
        printf 'FAKE-SIG-CONTENT\n' > "$outfile"
        exit 0
        ;;
    *.ipk)
        if [ "${STUB_IPK_MODE:-ok}" = "missing" ]; then
            exit 1
        fi
        printf 'FAKE-IPK-CONTENT\n' > "$outfile"
        exit 0
        ;;
    *)
        echo "stub wget: unexpected URL: $url" >&2
        exit 1
        ;;
esac
EOF

cat > "${WORKDIR}/stub-full/usign" <<'EOF'
#!/bin/sh
{ echo "ARGS:$*"; } >> "${USIGN_CALL_LOG:-/dev/null}"
prev=""
for a in "$@"; do
    if [ "$prev" = "-p" ] && [ -n "${USIGN_PUBKEY_CAPTURE:-}" ]; then
        cp "$a" "${USIGN_PUBKEY_CAPTURE}" 2>/dev/null || true
    fi
    prev="$a"
done
if [ "${STUB_USIGN_MODE:-ok}" = "fail" ]; then
    echo "usign: signature verification failed (stub)" >&2
    exit 1
fi
exit 0
EOF

chmod +x "${WORKDIR}/stub-full/uname" "${WORKDIR}/stub-full/pgrep" \
    "${WORKDIR}/stub-full/opkg" "${WORKDIR}/stub-full/wget" "${WORKDIR}/stub-full/usign"

# stub-nousign: same as stub-full, minus usign -- simulates a device that
# genuinely lacks the usign binary.
for f in uname pgrep opkg wget; do
    cp "${WORKDIR}/stub-full/${f}" "${WORKDIR}/stub-nousign/${f}"
    chmod +x "${WORKDIR}/stub-nousign/${f}"
done

run_ipk_path() {
    # run_ipk_path stub_dir -- sources install.sh in test mode and calls
    # ipk_path() with a fixed explicit version (bypasses get_latest_version
    # entirely), PATH prefixed with the given stub dir.
    _stubdir="$1"
    (
        INSTALL_SH_NO_MAIN=1
        export INSTALL_SH_NO_MAIN
        SCRIPT_DIR="${INSTALL_DIR}"
        export SCRIPT_DIR
        PATH="${_stubdir}:/usr/bin:/bin"
        export PATH
        . "${INSTALL_DIR}/install.sh"
        ipk_path "9.99.9"
    )
}

OPKG_INSTALL_LOG="${WORKDIR}/opkg-install.log"
USIGN_CALL_LOG="${WORKDIR}/usign-calls.log"
USIGN_PUBKEY_CAPTURE="${WORKDIR}/captured-pubkey.pub"
export OPKG_INSTALL_LOG USIGN_CALL_LOG USIGN_PUBKEY_CAPTURE

# --- A1: .sig download fails -> abort, never installs -------------------
rm -f "${OPKG_INSTALL_LOG}"
export STUB_SIG_MODE=missing STUB_IPK_MODE=ok STUB_USIGN_MODE=ok
if OUT=$(run_ipk_path "${WORKDIR}/stub-full" 2>"${WORKDIR}/a1.err"); then
    RC=0
else
    RC=$?
fi
assert_eq "A1 (sig missing): ipk_path aborts (nonzero exit)" "1" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"
assert_contains "A1 (sig missing): error mentions the failed .sig download" \
    "$(cat "${WORKDIR}/a1.err")" "Failed to download"
assert_contains "A1 (sig missing): error names the .sig URL" \
    "$(cat "${WORKDIR}/a1.err")" ".ipk.sig"
assert_eq "A1 (sig missing): opkg install was NEVER called" "" "$(cat "${OPKG_INSTALL_LOG}" 2>/dev/null || true)"

# --- A2: usign missing from PATH -> abort, never installs ---------------
rm -f "${OPKG_INSTALL_LOG}"
export STUB_SIG_MODE=ok STUB_IPK_MODE=ok STUB_USIGN_MODE=ok
if OUT=$(run_ipk_path "${WORKDIR}/stub-nousign" 2>"${WORKDIR}/a2.err"); then
    RC=0
else
    RC=$?
fi
assert_eq "A2 (usign absent): ipk_path aborts (nonzero exit)" "1" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"
assert_contains "A2 (usign absent): error explains usign is missing" \
    "$(cat "${WORKDIR}/a2.err")" "'usign' not found"
assert_eq "A2 (usign absent): opkg install was NEVER called" "" "$(cat "${OPKG_INSTALL_LOG}" 2>/dev/null || true)"

# --- A3: usign present but the signature is INVALID -> abort ------------
rm -f "${OPKG_INSTALL_LOG}" "${USIGN_CALL_LOG}"
export STUB_SIG_MODE=ok STUB_IPK_MODE=ok STUB_USIGN_MODE=fail
if OUT=$(run_ipk_path "${WORKDIR}/stub-full" 2>"${WORKDIR}/a3.err"); then
    RC=0
else
    RC=$?
fi
assert_eq "A3 (bad signature): ipk_path aborts (nonzero exit)" "1" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"
assert_contains "A3 (bad signature): error says verification FAILED" \
    "$(cat "${WORKDIR}/a3.err")" "Signature verification FAILED"
assert_eq "A3 (bad signature): opkg install was NEVER called" "" "$(cat "${OPKG_INSTALL_LOG}" 2>/dev/null || true)"
assert_contains "A3 (bad signature): usign was actually invoked with -V" \
    "$(cat "${USIGN_CALL_LOG}")" "-V"
assert_contains "A3 (bad signature): usign invoked with -m (message/package file)" \
    "$(cat "${USIGN_CALL_LOG}")" "-m"
assert_contains "A3 (bad signature): usign invoked with -x (signature file)" \
    "$(cat "${USIGN_CALL_LOG}")" "-x"

# --- A4 (GREEN control): valid signature -> verifies, installs ----------
rm -f "${OPKG_INSTALL_LOG}" "${USIGN_CALL_LOG}" "${USIGN_PUBKEY_CAPTURE}"
export STUB_SIG_MODE=ok STUB_IPK_MODE=ok STUB_USIGN_MODE=ok
if OUT=$(run_ipk_path "${WORKDIR}/stub-full" 2>"${WORKDIR}/a4.err"); then
    RC=0
else
    RC=$?
fi
assert_eq "A4 (valid signature): ipk_path SUCCEEDS (proves A1-A3 weren't vacuous)" "0" "$RC"
assert_contains "A4 (valid signature): logs 'Signature verified OK'" "$(cat "${WORKDIR}/a4.err")" "Signature verified OK"
assert_contains "A4 (valid signature): opkg install WAS called" "$(cat "${OPKG_INSTALL_LOG}")" "install:"
assert_contains "A4 (valid signature): the pubkey fed to usign -p matches the pinned signing.pub" \
    "$(cat "${USIGN_PUBKEY_CAPTURE}" 2>/dev/null || true)" "${PINNED_PUBKEY_LINE}"

unset STUB_SIG_MODE STUB_IPK_MODE STUB_USIGN_MODE

# =====================================================================
# Part B -- H2: apk_feed_key_sha256() pinned-key check
# =====================================================================
# NOTE ON DESIGN (see install.sh's own APK_FEED_KEY_SHA256 comment): this
# pins a plain SHA256 of the raw PEM bytes, NOT apk's internal SHA512-based
# key-id -- verified empirically against all four pinned OpenWrt 25.12
# rootfs images this repo tests against (tests/apk/.cache/*.tar.gz): none
# of them ship an `openssl` binary or any SHA-512 tool, only sha256sum. An
# openssl/SHA512-based check would always fail closed on the real target
# devices, so this test exercises the sha256sum-based mechanism actually
# shipped, not the SHA512 derivation the original finding described.
echo ""
echo "############################################"
echo "### Part B: H2 -- apk feed key pin (sha256)"
echo "############################################"

run_apk_key_sha256() {
    # run_apk_key_sha256 pemfile [path_prefix] -- sources install.sh in
    # test mode and calls apk_feed_key_sha256(pemfile) directly (no
    # /etc/apk/keys side effects -- that's the whole point of the
    # extraction).
    _pemfile="$1"
    _pathprefix="${2:-}"
    (
        INSTALL_SH_NO_MAIN=1
        export INSTALL_SH_NO_MAIN
        SCRIPT_DIR="${INSTALL_DIR}"
        export SCRIPT_DIR
        if [ -n "${_pathprefix}" ]; then
            PATH="${_pathprefix}"
        else
            PATH="/usr/bin:/bin"
        fi
        export PATH
        . "${INSTALL_DIR}/install.sh"
        apk_feed_key_sha256 "${_pemfile}"
    )
}

get_pinned_constant() {
    (
        INSTALL_SH_NO_MAIN=1
        export INSTALL_SH_NO_MAIN
        SCRIPT_DIR="${INSTALL_DIR}"
        export SCRIPT_DIR
        PATH="/usr/bin:/bin"
        export PATH
        . "${INSTALL_DIR}/install.sh"
        echo "${APK_FEED_KEY_SHA256}"
    )
}

PINNED=$(get_pinned_constant)
assert_eq "H2: install.sh's pinned APK_FEED_KEY_SHA256 matches sha256sum(apk-signing.pem)" \
    "$(sha256sum "${REPO_ROOT}/apk-signing.pem" | awk '{print $1}')" "${PINNED}"

if [ ! -f "${REPO_ROOT}/apk-signing.pem" ]; then
    echo "FAIL: ${REPO_ROOT}/apk-signing.pem not found (needed for H2's positive-match test)" >&2
    FAIL=1
else
    # --- B1: the REAL committed apk-signing.pem matches the pin ---------
    if SUM1=$(run_apk_key_sha256 "${REPO_ROOT}/apk-signing.pem"); then
        RC=0
    else
        RC=$?
    fi
    assert_eq "B1: apk_feed_key_sha256() succeeds on apk-signing.pem" "0" "${RC}"
    assert_eq "B1: sha256 of the real committed apk-signing.pem == pinned constant" "${PINNED}" "${SUM1}"
fi

# --- B2: a DIFFERENT EC key -> DIFFERENT sha256 (mismatch case) ---------
openssl ecparam -genkey -name prime256v1 -noout -out "${WORKDIR}/other.key" 2>/dev/null
openssl ec -in "${WORKDIR}/other.key" -pubout -out "${WORKDIR}/other-pub.pem" 2>/dev/null
if SUM2=$(run_apk_key_sha256 "${WORKDIR}/other-pub.pem"); then
    RC=0
else
    RC=$?
fi
assert_eq "B2: apk_feed_key_sha256() succeeds on a valid (but different) EC key" "0" "${RC}"
if [ "${SUM2}" != "${PINNED}" ]; then
    log_info "OK: B2: a different EC key's sha256 does NOT match the pin (this is the abort case apk_path() must reject)"
else
    log_fail "B2: a freshly generated, different EC key produced the SAME sha256 as the pin -- test is broken"
fi

# --- B3: a nonexistent file -> function fails cleanly -------------------
if SUM3=$(run_apk_key_sha256 "${WORKDIR}/does-not-exist.pem" 2>/dev/null); then
    RC=0
else
    RC=$?
fi
assert_eq "B3: apk_feed_key_sha256() returns nonzero on a missing file" "1" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"
assert_eq "B3: apk_feed_key_sha256() prints nothing on failure" "" "${SUM3}"

# --- B4: sha256sum missing -> fails closed (never silently trusts) -----
if SUM4=$(run_apk_key_sha256 "${REPO_ROOT}/apk-signing.pem" "/nonexistent-empty-path" 2>/dev/null); then
    RC=0
else
    RC=$?
fi
assert_eq "B4: apk_feed_key_sha256() returns nonzero when 'sha256sum' is missing" "1" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"
assert_eq "B4: apk_feed_key_sha256() prints nothing when 'sha256sum' is missing" "" "${SUM4}"

# =====================================================================
# Part C -- M9: -y/AUTO_YES propagates to the glinet path
# =====================================================================
echo ""
echo "############################################"
echo "### Part C: M9 -- -y/AUTO_YES propagation to the glinet path"
echo "############################################"

# --- C1: install.sh's glinet_path() forwards -y (and -v) correctly ------
FAKE_SCRIPT_DIR="${WORKDIR}/fake-scriptdir"
mkdir -p "${FAKE_SCRIPT_DIR}"
cp "${INSTALL_DIR}/lib-install.sh" "${FAKE_SCRIPT_DIR}/lib-install.sh"
cat > "${FAKE_SCRIPT_DIR}/install-glinet.sh" <<'EOF'
#!/bin/sh
echo "GLINET_ARGS:$*" >> "${GLINET_CALL_LOG:-/dev/null}"
exit 0
EOF
chmod +x "${FAKE_SCRIPT_DIR}/install-glinet.sh"

GLINET_CALL_LOG="${WORKDIR}/glinet-calls.log"
export GLINET_CALL_LOG

run_glinet_path() {
    # run_glinet_path auto_yes version -- sources install.sh in test mode,
    # points SCRIPT_DIR at a fake install-glinet.sh (that just logs its
    # argv), sets AUTO_YES directly (simulating main()'s already-parsed
    # -y/--yes), and calls glinet_path(version).
    _autoyes="$1"
    _version="$2"
    (
        INSTALL_SH_NO_MAIN=1
        export INSTALL_SH_NO_MAIN
        SCRIPT_DIR="${FAKE_SCRIPT_DIR}"
        export SCRIPT_DIR
        PATH="/usr/bin:/bin"
        export PATH
        . "${INSTALL_DIR}/install.sh"
        AUTO_YES="${_autoyes}"
        glinet_path "${_version}"
    )
}

rm -f "${GLINET_CALL_LOG}"
run_glinet_path "false" "" >/dev/null 2>&1 || true
assert_eq "C1a: AUTO_YES=false, no version: glinet gets no args at all" \
    "GLINET_ARGS:" "$(cat "${GLINET_CALL_LOG}")"

rm -f "${GLINET_CALL_LOG}"
run_glinet_path "true" "" >/dev/null 2>&1 || true
assert_eq "C1b: AUTO_YES=true, no version: -y IS forwarded (the M9 bug)" \
    "GLINET_ARGS:-y" "$(cat "${GLINET_CALL_LOG}")"

rm -f "${GLINET_CALL_LOG}"
run_glinet_path "true" "1.99.9" >/dev/null 2>&1 || true
assert_eq "C1c: AUTO_YES=true + version: both -v VERSION and -y are forwarded" \
    "GLINET_ARGS:-v 1.99.9 -y" "$(cat "${GLINET_CALL_LOG}")"

rm -f "${GLINET_CALL_LOG}"
run_glinet_path "false" "1.99.9" >/dev/null 2>&1 || true
assert_eq "C1d (control): AUTO_YES=false + version: -v forwarded, -y NOT forwarded" \
    "GLINET_ARGS:-v 1.99.9" "$(cat "${GLINET_CALL_LOG}")"

# --- C2: should_reinstall() actually SKIPS the prompt under AUTO_YES ----
# (not just "returns 0 either way because the default happens to be y in a
# non-interactive test shell" -- the load-bearing M9 property is that
# AUTO_YES short-circuits BEFORE prompt_confirm ever runs/prints.)
run_should_reinstall() {
    _autoyes="$1"
    (
        INSTALL_SH_NO_MAIN=1
        export INSTALL_SH_NO_MAIN
        SCRIPT_DIR="${INSTALL_DIR}"
        export SCRIPT_DIR
        PATH="/usr/bin:/bin"
        export PATH
        . "${INSTALL_DIR}/install.sh"
        AUTO_YES="${_autoyes}"
        should_reinstall
    )
}

run_should_reinstall "true" >/dev/null 2>"${WORKDIR}/c2-yes.err" || true
assert_not_contains "C2 (AUTO_YES=true): should_reinstall never even prints the prompt" \
    "$(cat "${WORKDIR}/c2-yes.err")" "Reinstall/upgrade anyway?"

run_should_reinstall "false" >/dev/null 2>"${WORKDIR}/c2-no.err" || true
assert_contains "C2 control (AUTO_YES=false): should_reinstall DOES print the prompt" \
    "$(cat "${WORKDIR}/c2-no.err")" "Reinstall/upgrade anyway?"

# --- C3: structural check -- install-glinet.sh honors the shared -------
# convention (single authored should_reinstall()/AUTO_YES in lib-install.sh,
# no bespoke duplicate; -y/--yes is parsed; the old un-yes-able inline
# prompt is gone).
GLINET_SRC=$(cat "${INSTALL_DIR}/install-glinet.sh")
assert_contains "C3: install-glinet.sh parses -y/--yes" "${GLINET_SRC}" '-y|--yes)'
assert_contains "C3: install-glinet.sh's reinstall guard calls the shared should_reinstall" \
    "${GLINET_SRC}" "should_reinstall"
assert_not_contains "C3: install-glinet.sh no longer has its own un-yes-able 'Reinstall anyway?' prompt" \
    "${GLINET_SRC}" 'prompt_confirm "Reinstall anyway?"'
assert_not_contains "C3: install-glinet.sh does not redefine should_reinstall itself" \
    "${GLINET_SRC}" 'should_reinstall() {'

N=$(grep -rl "^should_reinstall() {" "${REPO_ROOT}/scripts"/*.sh 2>/dev/null | wc -l | tr -d ' ')
assert_eq "C3: exactly one authored definition of should_reinstall() in scripts/*.sh" "1" "${N}"
OWNER=$(grep -l "^should_reinstall() {" "${REPO_ROOT}/scripts"/*.sh 2>/dev/null | xargs -n1 basename)
assert_eq "C3: should_reinstall() lives in lib-install.sh (promoted, not re-copy-pasted)" "lib-install.sh" "${OWNER}"

# =====================================================================
# Part D -- L9: tailscaled_current_version() never silently returns empty
# =====================================================================
echo ""
echo "############################################"
echo "### Part D: L9 -- tailscaled_current_version() fallback"
echo "############################################"

cat > "${WORKDIR}/tailscaled-ok" <<'EOF'
#!/bin/sh
echo "1.94.1 track-abc123"
EOF
chmod +x "${WORKDIR}/tailscaled-ok"

cat > "${WORKDIR}/tailscaled-broken" <<'EOF'
#!/bin/sh
# Simulates a broken/non-responsive binary: exits nonzero, prints nothing.
exit 1
EOF
chmod +x "${WORKDIR}/tailscaled-broken"

echo "not a real binary" > "${WORKDIR}/tailscaled-noexec"
chmod -x "${WORKDIR}/tailscaled-noexec" 2>/dev/null || true

run_current_version() {
    _bin="$1"
    (
        INSTALL_GLINET_SH_NO_MAIN=1
        export INSTALL_GLINET_SH_NO_MAIN
        SCRIPT_DIR="${INSTALL_DIR}"
        export SCRIPT_DIR
        PATH="/usr/bin:/bin"
        export PATH
        . "${INSTALL_DIR}/install-glinet.sh"
        tailscaled_current_version "${_bin}"
    )
}

OUT=$(run_current_version "${WORKDIR}/does-not-exist") || true
assert_eq "D1: missing binary -> unknown" "unknown" "${OUT}"

OUT=$(run_current_version "${WORKDIR}/tailscaled-noexec") || true
assert_eq "D2: non-executable file -> unknown" "unknown" "${OUT}"

OUT=$(run_current_version "${WORKDIR}/tailscaled-ok") || true
assert_eq "D3 (control): a real, working binary -> its actual version" "1.94.1" "${OUT}"

OUT=$(run_current_version "${WORKDIR}/tailscaled-broken") || true
assert_eq "D4 (the L9 bug): broken binary (exits nonzero, no stdout) -> 'unknown', never empty" \
    "unknown" "${OUT}"

# =====================================================================
# Part E -- FIX1: should_reinstall()'s default answer is "n", not "y"
# =====================================================================
echo ""
echo "############################################"
echo "### Part E: FIX1 -- should_reinstall() defaults to NO"
echo "############################################"

# E1: the actual regression -- unattended (no -y/AUTO_YES, and /dev/tty
# can't be meaningfully read in this harness) must be a safe NO-OP. The M9
# refactor was only supposed to propagate -y/AUTO_YES as a shared escape
# hatch; it must not also flip the prompt's own default from install-glinet.sh's
# ORIGINAL "N" to "y".
if run_should_reinstall "false" >/dev/null 2>/dev/null; then RC=0; else RC=$?; fi
assert_eq "E1: should_reinstall() default is NO -- unattended re-run without -y is a safe no-op" \
    "1" "$([ "${RC}" -ne 0 ] && echo 1 || echo 0)"

# E2 (control): AUTO_YES=true must still proceed -- proves E1 isn't vacuous
# (i.e. should_reinstall isn't just ALWAYS returning 1).
if run_should_reinstall "true" >/dev/null 2>/dev/null; then RC=0; else RC=$?; fi
assert_eq "E2 (control): should_reinstall() with AUTO_YES=true still proceeds" \
    "0" "${RC}"

# E3: structural guard -- lib-install.sh passes an explicit "n" default to
# prompt_confirm (never "y"), so a future edit can't silently re-flip this.
LIB_SRC=$(cat "${INSTALL_DIR}/lib-install.sh")
assert_contains "E3: should_reinstall() passes an explicit 'n' default to prompt_confirm" \
    "${LIB_SRC}" 'prompt_confirm "Reinstall/upgrade anyway?" n'
assert_not_contains "E3: should_reinstall() no longer defaults to 'y'" \
    "${LIB_SRC}" 'prompt_confirm "Reinstall/upgrade anyway?" y'

# =====================================================================
# Part F -- FIX1: the reinstall gate at the actual ipk_path()/apk_path()
# call sites (not just should_reinstall() in isolation)
# =====================================================================
echo ""
echo "############################################"
echo "### Part F: FIX1 -- non-interactive reinstall gate (ipk_path / apk_path)"
echo "############################################"

# --- F1/F2: ipk_path(), already installed -----------------------------
export STUB_SIG_MODE=ok STUB_IPK_MODE=ok STUB_USIGN_MODE=ok
export STUB_OPKG_INFO_VERSION="9.99.9-1" STUB_OPKG_INFO_ARCH="aarch64_cortex-a53"
export STUB_OPKG_INSTALLED=yes

rm -f "${OPKG_INSTALL_LOG}"
unset AUTO_YES
if OUT=$(run_ipk_path "${WORKDIR}/stub-full" 2>"${WORKDIR}/f1.err"); then
    RC=0
else
    RC=$?
fi
assert_eq "F1: ipk_path() already-installed + no -y: SUCCEEDS (no-op, not an error)" "0" "${RC}"
assert_contains "F1: ipk_path() leaves the existing install in place" \
    "$(cat "${WORKDIR}/f1.err")" "Leaving the existing installation in place"
assert_eq "F1: ipk_path() already-installed + no -y: opkg install NEVER called" \
    "" "$(cat "${OPKG_INSTALL_LOG}" 2>/dev/null || true)"

rm -f "${OPKG_INSTALL_LOG}"
export AUTO_YES=true
if OUT=$(run_ipk_path "${WORKDIR}/stub-full" 2>"${WORKDIR}/f2.err"); then
    RC=0
else
    RC=$?
fi
assert_eq "F2: ipk_path() already-installed + -y: SUCCEEDS (reinstalls)" "0" "${RC}"
assert_not_contains "F2: ipk_path() does NOT leave the existing install in place when -y is given" \
    "$(cat "${WORKDIR}/f2.err")" "Leaving the existing installation in place"
assert_contains "F2: ipk_path() already-installed + -y: opkg install WAS called" \
    "$(cat "${OPKG_INSTALL_LOG}")" "install:"

unset AUTO_YES STUB_OPKG_INSTALLED STUB_SIG_MODE STUB_IPK_MODE STUB_USIGN_MODE \
    STUB_OPKG_INFO_VERSION STUB_OPKG_INFO_ARCH

# --- F3/F4: apk_path(), already installed -----------------------------
# apk_path() touches real absolute paths (/etc/apk/keys, .../repositories.d)
# once it proceeds past the reinstall gate -- never safe to let it run to
# completion outside a container (see tests/apk/install-dispatch.sh Part 4
# for that). So `mkdir` and `wget` are stubbed here too (never the real
# binaries), and the stubbed `wget` deliberately FAILS the feed-key fetch --
# a clean, deterministic abort a few lines after the gate, proving the gate
# was passed without ever touching the real filesystem or network.
mkdir -p "${WORKDIR}/stub-apkpath"
cat > "${WORKDIR}/stub-apkpath/uname" <<'EOF'
#!/bin/sh
echo aarch64
EOF
cat > "${WORKDIR}/stub-apkpath/apk" <<'EOF'
#!/bin/sh
if [ "$1" = "info" ] && [ "$2" = "-e" ] && [ "$3" = "tailscale" ]; then
    exit 0
fi
exit 1
EOF

# The feed arch comes from /etc/apk/arch (APK_ARCH_FILE), not a command.
# Point it at a fixture holding aarch64_generic ON PURPOSE: the stub `uname`
# above reports "aarch64", which the old detect_arch mapping turned into
# aarch64_cortex-a53. aarch64_generic is a value that mapping can NEVER
# produce, so asserting apk_path reports it proves the arch now tracks the
# device's own /etc/apk/arch rather than a uname guess.
APK_ARCH_FIXTURE="${WORKDIR}/etc-apk-arch"
printf 'aarch64_generic\n' > "${APK_ARCH_FIXTURE}"
cat > "${WORKDIR}/stub-apkpath/mkdir" <<'EOF'
#!/bin/sh
echo "mkdir:$*" >> "${MKDIR_CALL_LOG:-/dev/null}"
exit 0
EOF
cat > "${WORKDIR}/stub-apkpath/wget" <<'EOF'
#!/bin/sh
echo "wget:$*" >> "${WGET_CALL_LOG:-/dev/null}"
exit 1
EOF
chmod +x "${WORKDIR}/stub-apkpath/uname" "${WORKDIR}/stub-apkpath/apk" \
    "${WORKDIR}/stub-apkpath/mkdir" "${WORKDIR}/stub-apkpath/wget"

MKDIR_CALL_LOG="${WORKDIR}/mkdir-calls.log"
WGET_CALL_LOG="${WORKDIR}/wget-calls.log"
export MKDIR_CALL_LOG WGET_CALL_LOG

run_apk_path_gate() {
    _autoyes="$1"
    (
        INSTALL_SH_NO_MAIN=1
        export INSTALL_SH_NO_MAIN
        SCRIPT_DIR="${INSTALL_DIR}"
        export SCRIPT_DIR
        OPKG_INFO_DIR="${WORKDIR}/no-such-opkg-info-dir"
        export OPKG_INFO_DIR
        APK_ARCH_FILE="${APK_ARCH_FIXTURE}"
        export APK_ARCH_FILE
        PATH="${WORKDIR}/stub-apkpath:/usr/bin:/bin"
        export PATH
        . "${INSTALL_DIR}/install.sh"
        AUTO_YES="${_autoyes}"
        apk_path
    )
}

rm -f "${MKDIR_CALL_LOG}" "${WGET_CALL_LOG}"
if OUT=$(run_apk_path_gate "false" 2>"${WORKDIR}/f3.err"); then
    RC=0
else
    RC=$?
fi
assert_eq "F3: apk_path() already-installed + no -y: SUCCEEDS (no-op, not an error)" "0" "${RC}"
assert_contains "F3: apk_path() leaves the existing install in place" \
    "$(cat "${WORKDIR}/f3.err")" "Leaving the existing installation in place"
assert_eq "F3: apk_path() already-installed + no -y: never touches /etc/apk (mkdir never called)" \
    "" "$(cat "${MKDIR_CALL_LOG}" 2>/dev/null || true)"
assert_eq "F3: apk_path() already-installed + no -y: never fetches the feed key (wget never called)" \
    "" "$(cat "${WGET_CALL_LOG}" 2>/dev/null || true)"

rm -f "${MKDIR_CALL_LOG}" "${WGET_CALL_LOG}"
if OUT=$(run_apk_path_gate "true" 2>"${WORKDIR}/f4.err"); then
    RC=0
else
    RC=$?
fi
assert_eq "F4: apk_path() already-installed + -y: proceeds far enough to hit the stubbed-failing key fetch" \
    "1" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"
assert_not_contains "F4: apk_path() does NOT leave the existing install in place when -y is given" \
    "$(cat "${WORKDIR}/f4.err")" "Leaving the existing installation in place"
assert_contains "F4: apk_path() already-installed + -y: proceeds to touch /etc/apk (mkdir called)" \
    "$(cat "${MKDIR_CALL_LOG}" 2>/dev/null || true)" "mkdir:"
# Generic arch: the stub `uname` reports "aarch64" (which the old detect_arch
# mapping would have turned into aarch64_cortex-a53), but /etc/apk/arch
# (APK_ARCH_FILE fixture) holds aarch64_generic -- apk_path must use the file,
# so the feed arch tracks whatever the device actually is.
assert_contains "F4: apk_path() takes the feed arch from /etc/apk/arch, not the uname guess" \
    "$(cat "${WORKDIR}/f4.err")" "arch aarch64_generic (from"

# =====================================================================
# Part G -- FIX3: ipk_path() control-version/arch identity binding
# =====================================================================
echo ""
echo "############################################"
echo "### Part G: FIX3 -- ipk_path() control-version/arch binding"
echo "############################################"

export STUB_SIG_MODE=ok STUB_IPK_MODE=ok STUB_USIGN_MODE=ok

# --- G1: control Version doesn't match the requested version -> abort ---
rm -f "${OPKG_INSTALL_LOG}"
export STUB_OPKG_INFO_VERSION="1.0.0-1" STUB_OPKG_INFO_ARCH="aarch64_cortex-a53"
if OUT=$(run_ipk_path "${WORKDIR}/stub-full" 2>"${WORKDIR}/g1.err"); then
    RC=0
else
    RC=$?
fi
assert_eq "G1 (version mismatch): ipk_path aborts (nonzero exit)" "1" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"
assert_contains "G1 (version mismatch): error says identity MISMATCH" \
    "$(cat "${WORKDIR}/g1.err")" "identity MISMATCH"
assert_contains "G1 (version mismatch): error names the requested version" \
    "$(cat "${WORKDIR}/g1.err")" "requested version 9.99.9"
assert_eq "G1 (version mismatch): opkg install was NEVER called" \
    "" "$(cat "${OPKG_INSTALL_LOG}" 2>/dev/null || true)"

# --- G2: control Architecture doesn't match the detected arch -> abort --
rm -f "${OPKG_INSTALL_LOG}"
export STUB_OPKG_INFO_VERSION="9.99.9-1" STUB_OPKG_INFO_ARCH="mips_24kc"
if OUT=$(run_ipk_path "${WORKDIR}/stub-full" 2>"${WORKDIR}/g2.err"); then
    RC=0
else
    RC=$?
fi
assert_eq "G2 (arch mismatch): ipk_path aborts (nonzero exit)" "1" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"
assert_contains "G2 (arch mismatch): error says identity MISMATCH" \
    "$(cat "${WORKDIR}/g2.err")" "identity MISMATCH"
assert_eq "G2 (arch mismatch): opkg install was NEVER called" \
    "" "$(cat "${OPKG_INSTALL_LOG}" 2>/dev/null || true)"

# --- G3 (GREEN control): matching identity -> proceeds to install -------
# (proves G1/G2 weren't vacuous -- the check can actually pass)
rm -f "${OPKG_INSTALL_LOG}"
export STUB_OPKG_INFO_VERSION="9.99.9-1" STUB_OPKG_INFO_ARCH="aarch64_cortex-a53"
if OUT=$(run_ipk_path "${WORKDIR}/stub-full" 2>"${WORKDIR}/g3.err"); then
    RC=0
else
    RC=$?
fi
assert_eq "G3 (control): matching identity -- ipk_path SUCCEEDS" "0" "${RC}"
assert_contains "G3 (control): logs the verified package identity" \
    "$(cat "${WORKDIR}/g3.err")" "Package identity verified"
assert_contains "G3 (control): opkg install WAS called" "$(cat "${OPKG_INSTALL_LOG}")" "install:"

# --- G4: opkg info fails outright (corrupt/unparseable file) -> abort ---
rm -f "${OPKG_INSTALL_LOG}"
unset STUB_OPKG_INFO_VERSION STUB_OPKG_INFO_ARCH
export STUB_OPKG_INFO_MODE=fail
if OUT=$(run_ipk_path "${WORKDIR}/stub-full" 2>"${WORKDIR}/g4.err"); then
    RC=0
else
    RC=$?
fi
assert_eq "G4 (opkg info fails): ipk_path aborts (nonzero exit)" "1" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"
assert_contains "G4 (opkg info fails): error explains control metadata could not be read" \
    "$(cat "${WORKDIR}/g4.err")" "control metadata"
assert_eq "G4 (opkg info fails): opkg install was NEVER called" \
    "" "$(cat "${OPKG_INSTALL_LOG}" 2>/dev/null || true)"

unset STUB_SIG_MODE STUB_IPK_MODE STUB_USIGN_MODE STUB_OPKG_INFO_MODE \
    STUB_OPKG_INFO_VERSION STUB_OPKG_INFO_ARCH

# =====================================================================
# Part H -- FIX2: shared sha256_verify() primitive
# =====================================================================
echo ""
echo "############################################"
echo "### Part H: FIX2 -- sha256_verify() shared primitive"
echo "############################################"

run_sha256_verify() {
    _file="$1"
    _expected="$2"
    _pathprefix="${3:-/usr/bin:/bin}"
    (
        PATH="${_pathprefix}"
        export PATH
        . "${INSTALL_DIR}/lib-install.sh"
        sha256_verify "${_file}" "${_expected}"
    )
}

echo "hello world" > "${WORKDIR}/h-file.txt"
H_SUM=$(sha256sum "${WORKDIR}/h-file.txt" | awk '{print $1}')
ZEROSUM=$(printf '%064d' 0)

if run_sha256_verify "${WORKDIR}/h-file.txt" "${H_SUM}"; then RC=0; else RC=$?; fi
assert_eq "H1: sha256_verify() succeeds on a matching digest" "0" "${RC}"

if run_sha256_verify "${WORKDIR}/h-file.txt" "${ZEROSUM}"; then RC=0; else RC=$?; fi
assert_eq "H2: sha256_verify() fails on a mismatched digest" "1" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"

if run_sha256_verify "${WORKDIR}/does-not-exist-h.txt" "${H_SUM}"; then RC=0; else RC=$?; fi
assert_eq "H3: sha256_verify() fails closed on a missing file" "1" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"

if run_sha256_verify "${WORKDIR}/h-file.txt" "${H_SUM}" "/nonexistent-empty-path"; then RC=0; else RC=$?; fi
assert_eq "H4: sha256_verify() fails closed when 'sha256sum' is missing" "1" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"

# H5: structural -- both round-2-identified duplicate checks now route
# through this ONE shared primitive instead of reimplementing the compare,
# and there is exactly one authored definition of it.
INSTALL_SRC=$(cat "${INSTALL_DIR}/install.sh")
assert_contains "H5: install.sh's apk_path() routes its key-pin compare through sha256_verify" \
    "${INSTALL_SRC}" 'sha256_verify "${_key_tmp}" "${APK_FEED_KEY_SHA256}"'
GLINET_SRC2=$(cat "${INSTALL_DIR}/install-glinet.sh")
assert_contains "H5: install-glinet.sh's binary check routes through sha256_verify" \
    "${GLINET_SRC2}" "sha256_verify"
N2=$(grep -rl "^sha256_verify() {" "${REPO_ROOT}/scripts"/*.sh 2>/dev/null | wc -l | tr -d ' ')
assert_eq "H5: exactly one authored definition of sha256_verify() in scripts/*.sh" "1" "${N2}"
OWNER2=$(grep -l "^sha256_verify() {" "${REPO_ROOT}/scripts"/*.sh 2>/dev/null | xargs -n1 basename)
assert_eq "H5: sha256_verify() lives in lib-install.sh (shared, not copy-pasted)" "lib-install.sh" "${OWNER2}"

# =====================================================================
# Part I -- FIX4: install-glinet.sh verifies SHA256SUMS.sig before trusting
# SHA256SUMS (closes the same-untrusted-host-verifies-itself gap)
# =====================================================================
echo ""
echo "############################################"
echo "### Part I: FIX4 -- install-glinet.sh SHA256SUMS.sig verification"
echo "############################################"

# I0: structural -- the pinned usign key is shared via lib-install.sh, not
# duplicated between install.sh and install-glinet.sh.
assert_not_contains "I0: install.sh no longer bakes its own copy of TAILSCALE_USIGN_PUBKEY" \
    "${INSTALL_SRC}" "TAILSCALE_USIGN_PUBKEY='untrusted comment"
assert_contains "I0: TAILSCALE_USIGN_PUBKEY is defined in lib-install.sh (the single shared copy)" \
    "${LIB_SRC}" "TAILSCALE_USIGN_PUBKEY='untrusted comment"
N3=$(grep -rl "^TAILSCALE_USIGN_PUBKEY=" "${REPO_ROOT}/scripts"/*.sh 2>/dev/null | wc -l | tr -d ' ')
assert_eq "I0: exactly one authored definition of TAILSCALE_USIGN_PUBKEY in scripts/*.sh" "1" "${N3}"

GLINET_VERSION="9.99.9"
GLINET_ARCH="aarch64_cortex-a53"

mkdir -p "${WORKDIR}/stub-glinet-full" "${WORKDIR}/stub-glinet-nousign"

# download_binary() doesn't just check the hash -- it also chmod +x's the
# result and execs `"$tmpfile" --version` as a final sanity check (real
# code, unchanged by this fix), so the fake payload must actually be a
# valid, executable script that responds to --version, not just arbitrary
# bytes.
printf '#!/bin/sh\necho "9.99.9"\n' > "${WORKDIR}/expected-binary-content"
chmod +x "${WORKDIR}/expected-binary-content"
EXPECTED_BIN_SUM=$(sha256sum "${WORKDIR}/expected-binary-content" | awk '{print $1}')
printf '%s  tailscaled_%s_%s\n' "${EXPECTED_BIN_SUM}" "${GLINET_VERSION}" "${GLINET_ARCH}" > "${WORKDIR}/stub-sums-file-good"
STUB_SUMS_FILE="${WORKDIR}/stub-sums-file-good"
export STUB_SUMS_FILE

cat > "${WORKDIR}/stub-glinet-full/wget" <<'EOF'
#!/bin/sh
outfile="$2"
url="$3"
case "$url" in
    *SHA256SUMS.sig)
        if [ "${STUB_SUMS_SIG_MODE:-ok}" = "missing" ]; then
            exit 1
        fi
        printf 'FAKE-SUMS-SIG-CONTENT\n' > "$outfile"
        exit 0
        ;;
    *SHA256SUMS)
        if [ "${STUB_SUMS_MODE:-ok}" = "missing" ]; then
            exit 1
        fi
        cp "${STUB_SUMS_FILE}" "$outfile"
        exit 0
        ;;
    *)
        if [ "${STUB_BIN_MODE:-ok}" = "missing" ]; then
            exit 1
        fi
        printf '#!/bin/sh\necho "9.99.9"\n' > "$outfile"
        exit 0
        ;;
esac
EOF

cat > "${WORKDIR}/stub-glinet-full/usign" <<'EOF'
#!/bin/sh
{ echo "ARGS:$*"; } >> "${USIGN_CALL_LOG2:-/dev/null}"
if [ "${STUB_USIGN_SUMS_MODE:-ok}" = "fail" ]; then
    echo "usign: signature verification failed (stub)" >&2
    exit 1
fi
exit 0
EOF

chmod +x "${WORKDIR}/stub-glinet-full/wget" "${WORKDIR}/stub-glinet-full/usign"
cp "${WORKDIR}/stub-glinet-full/wget" "${WORKDIR}/stub-glinet-nousign/wget"
chmod +x "${WORKDIR}/stub-glinet-nousign/wget"

USIGN_CALL_LOG2="${WORKDIR}/usign-calls2.log"
export USIGN_CALL_LOG2

run_download_binary() {
    _stubdir="$1"
    (
        INSTALL_GLINET_SH_NO_MAIN=1
        export INSTALL_GLINET_SH_NO_MAIN
        SCRIPT_DIR="${INSTALL_DIR}"
        export SCRIPT_DIR
        PATH="${_stubdir}:/usr/bin:/bin"
        export PATH
        . "${INSTALL_DIR}/install-glinet.sh"
        download_binary "${GLINET_VERSION}" "${GLINET_ARCH}"
    )
}

# --- I1: SHA256SUMS.sig missing -> abort ---------------------------------
export STUB_SUMS_SIG_MODE=missing STUB_SUMS_MODE=ok STUB_BIN_MODE=ok STUB_USIGN_SUMS_MODE=ok
if OUT=$(run_download_binary "${WORKDIR}/stub-glinet-full" 2>"${WORKDIR}/i1.err"); then
    RC=0
else
    RC=$?
fi
assert_eq "I1 (SHA256SUMS.sig missing): download_binary aborts (nonzero exit)" \
    "1" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"
assert_contains "I1 (SHA256SUMS.sig missing): error mentions the failed .sig download" \
    "$(cat "${WORKDIR}/i1.err")" "Failed to download SHA256SUMS.sig"

# --- I2: SHA256SUMS.sig present but INVALID -> abort (tampered SHA256SUMS)
export STUB_SUMS_SIG_MODE=ok STUB_USIGN_SUMS_MODE=fail
rm -f "${USIGN_CALL_LOG2}"
if OUT=$(run_download_binary "${WORKDIR}/stub-glinet-full" 2>"${WORKDIR}/i2.err"); then
    RC=0
else
    RC=$?
fi
assert_eq "I2 (bad SHA256SUMS signature): download_binary aborts (nonzero exit)" \
    "1" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"
assert_contains "I2 (bad SHA256SUMS signature): error says SHA256SUMS signature verification FAILED" \
    "$(cat "${WORKDIR}/i2.err")" "SHA256SUMS signature verification FAILED"
assert_contains "I2: usign was actually invoked with -V" "$(cat "${USIGN_CALL_LOG2}")" "-V"

# --- I3: usign missing from PATH -> abort, never trusts SHA256SUMS ------
export STUB_USIGN_SUMS_MODE=ok
if OUT=$(run_download_binary "${WORKDIR}/stub-glinet-nousign" 2>"${WORKDIR}/i3.err"); then
    RC=0
else
    RC=$?
fi
assert_eq "I3 (usign absent): download_binary aborts (nonzero exit)" \
    "1" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"
assert_contains "I3 (usign absent): error explains usign is missing" \
    "$(cat "${WORKDIR}/i3.err")" "'usign' not found"

# --- I4 (GREEN control): valid sig + matching checksum -> succeeds ------
if OUT=$(run_download_binary "${WORKDIR}/stub-glinet-full" 2>"${WORKDIR}/i4.err"); then
    RC=0
else
    RC=$?
fi
assert_eq "I4 (valid): download_binary SUCCEEDS (proves I1-I3 weren't vacuous)" "0" "${RC}"
assert_contains "I4 (valid): logs SHA256SUMS signature verified OK" \
    "$(cat "${WORKDIR}/i4.err")" "SHA256SUMS signature verified OK"
assert_contains "I4 (valid): logs SHA256 verified OK" "$(cat "${WORKDIR}/i4.err")" "SHA256 verified OK"
rm -f "${OUT}" 2>/dev/null || true

# --- I5: valid signature but the binary's hash doesn't match the (still
# signature-verified) SHA256SUMS entry -> abort. Proves the signature check
# doesn't replace the hash check -- both are required.
printf '%s  tailscaled_%s_%s\n' "${ZEROSUM}" "${GLINET_VERSION}" "${GLINET_ARCH}" > "${WORKDIR}/stub-sums-file-bad"
STUB_SUMS_FILE="${WORKDIR}/stub-sums-file-bad"
export STUB_SUMS_FILE
if OUT=$(run_download_binary "${WORKDIR}/stub-glinet-full" 2>"${WORKDIR}/i5.err"); then
    RC=0
else
    RC=$?
fi
assert_eq "I5 (checksum mismatch despite valid sig): download_binary aborts (nonzero exit)" \
    "1" "$([ "$RC" -ne 0 ] && echo 1 || echo 0)"
assert_contains "I5: error says SHA256 verification FAILED" \
    "$(cat "${WORKDIR}/i5.err")" "SHA256 verification FAILED"

unset STUB_SUMS_SIG_MODE STUB_SUMS_MODE STUB_BIN_MODE STUB_USIGN_SUMS_MODE STUB_SUMS_FILE

harness_finish "tests/apk/install-verify.sh"
