#!/bin/sh
# tests/apk/publish-arch.sh
#
# H6/H7/H3 test: scripts/publish-arch.sh is the extracted single
# implementation of the per-arch "assemble + sign + guard + retain"
# pipeline that used to be duplicated byte-for-byte between the
# `publish-feed` and `republish-feed` workflow jobs (RFC
# docs/rfc-apk-builds.md §4.3/§4.6). This test exercises the SCRIPT's own
# arg handling and decision logic directly -- not a live Docker/imprimatur/
# Pages round-trip (that end-to-end proof is tests/apk/feed-publish.sh's and
# tests/apk/sign-verify.sh's job) -- by stubbing out apk/adb-sign.py/
# feed-guard.sh/curl via publish-arch.sh's own overridable env vars (and a
# PATH-shimmed `curl` for the bare `curl` calls), so it runs in milliseconds
# with no docker/network dependency.
#
# Covers:
#   1. Usage/arg-handling errors: too few args, an unknown flag, a missing
#      apk file, an empty/slash-containing published filename, a missing
#      pubkey -- all exit non-zero with a clear message.
#   2. Happy path: the apk is copied to
#      <pages-root>/apk/<arch>/<published-filename>, the stubbed pipeline
#      runs in order, packages.adb + retained.json land correctly, and
#      intermediate scratch files (unsigned.adb/preimage.bin/sig.der) are
#      cleaned up.
#   2b. FIX1 (round-3): an explicit <published-filename> that DIFFERS from
#      the source apk-file's own basename is honored verbatim -- the file
#      lands under the published name, never the source name -- proving
#      publish-arch.sh no longer derives the on-disk name via basename()
#      (the RENAMED_ROOT/sed/cp side-pipeline republish-feed used to need is
#      no longer necessary).
#   3. H7 hard gate (RED proof): when the stubbed `adb-sign.py verify` fails,
#      publish-arch.sh exits non-zero AND never even calls feed-guard.sh --
#      proving the verify-before-publish gate runs BEFORE the monotonicity/
#      retention/deploy decision, not just "eventually checked somewhere".
#   4. Monotonicity propagation: when the stubbed feed-guard.sh
#      check-monotonic rejects (exit 1), publish-arch.sh propagates that
#      failure and never reaches plan-retention (retained.json not written).
#   5. --force forwarding: the stubbed feed-guard.sh log shows --force
#      present/absent on check-monotonic exactly matching whether
#      publish-arch.sh was invoked with --force.
#   6. H3/FIX3: the IMPRIMATUR_AUTH_TOKEN value reaches the sign POST as an
#      `Authorization: Bearer <token>` header -- but via curl's `-H @<file>`
#      mechanism, NEVER as a literal argv token (the stubbed curl's own
#      argv log, which stands in for what a real `ps` snapshot would show,
#      must never contain the raw token) -- including the backward-
#      compatible empty-token case.
#   7. FIX4 (RED proof): a sign-POST curl failure (simulated 401/5xx via the
#      stubbed curl's exit code) aborts loudly and immediately -- exit
#      non-zero, a "curl error" message identifying the cause, and
#      packages.adb never written -- rather than silently falling through to
#      the empty/null signature check.
#
# Usage: sh tests/apk/publish-arch.sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
PUBLISH_ARCH="${REPO_ROOT}/scripts/publish-arch.sh"

# shellcheck source=tests/apk/lib.sh
. "${SCRIPT_DIR}/lib.sh"

require_cmd jq
require_cmd python3
require_cmd base64

if [ ! -f "${PUBLISH_ARCH}" ]; then
    echo "FAIL: ${PUBLISH_ARCH} not found" >&2
    exit 1
fi
if [ ! -x "${PUBLISH_ARCH}" ]; then
    echo "FAIL: ${PUBLISH_ARCH} exists but is not executable" >&2
    exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "${WORKDIR}"' EXIT

# ---------------------------------------------------------------------------
# fixtures: a dummy .apk + pubkey, and stub apk/adb-sign.py/feed-guard.sh/curl
# ---------------------------------------------------------------------------
mkdir -p "${WORKDIR}/src" "${WORKDIR}/bin"

SRC_APK="${WORKDIR}/src/tailscale-1.99.0-r1.apk"
printf 'DUMMY-APK-BYTES' > "${SRC_APK}"

# A second source fixture whose ON-DISK name carries an arch suffix, mimicking
# release-apk-assets' loose release-asset naming (tailscale-<ver>-r<rel>-<arch>.apk)
# -- used by the 2b FIX1 test below to prove an explicit published filename
# that DIFFERS from this basename is honored, not silently overridden.
SRC_APK_ARCHSUFFIXED="${WORKDIR}/src/tailscale-1.99.0-r1-aarch64_cortex-a53.apk"
printf 'DUMMY-APK-BYTES' > "${SRC_APK_ARCHSUFFIXED}"

PUBKEY="${WORKDIR}/src/apk-signing.pem"
printf -- '-----BEGIN PUBLIC KEY-----\nDUMMY\n-----END PUBLIC KEY-----\n' > "${PUBKEY}"

# --- stub apk (only `mkndx --output <file> ...` matters here) -------------
FAKE_APK="${WORKDIR}/bin/fake-apk.sh"
cat > "${FAKE_APK}" <<'EOF'
#!/bin/sh
prev=""
out=""
for a in "$@"; do
    if [ "${prev}" = "--output" ]; then out="${a}"; fi
    prev="${a}"
done
[ -n "${out}" ] || { echo "fake-apk: no --output given: $*" >&2; exit 1; }
printf 'FAKE-UNSIGNED-INDEX' > "${out}"
EOF
chmod +x "${FAKE_APK}"

# --- stub adb-sign.py (preimage/assemble/verify) --------------------------
FAKE_ADB_SIGN="${WORKDIR}/bin/fake-adb-sign.py"
cat > "${FAKE_ADB_SIGN}" <<'EOF'
#!/usr/bin/env python3
import os
import sys

cmd = sys.argv[1]
marker = os.environ.get("FAKE_SIGNED_MARKER", "SIGNED-OK").encode()

if cmd == "preimage":
    out = sys.argv[4]
    with open(out, "wb") as f:
        f.write(b"FAKE-PREIMAGE")
elif cmd == "assemble":
    unsigned, _pub, sig, out = sys.argv[2:6]
    with open(unsigned, "rb") as f:
        data = f.read()
    with open(sig, "rb") as f:
        sigdata = f.read()
    with open(out, "wb") as f:
        f.write(data + b"::" + marker + b"::" + sigdata)
elif cmd == "verify":
    signed = sys.argv[2]
    with open(signed, "rb") as f:
        data = f.read()
    result = os.environ.get("FAKE_VERIFY_RESULT", "VALID")
    if result == "VALID" and marker in data:
        print("VALID")
        sys.exit(0)
    print("INVALID: forced test failure", file=sys.stderr)
    sys.exit(1)
else:
    print(f"fake-adb-sign.py: unknown subcommand {cmd}", file=sys.stderr)
    sys.exit(2)
EOF
chmod +x "${FAKE_ADB_SIGN}"

# --- stub feed-guard.sh (check-monotonic/plan-retention) -------------------
FAKE_FEED_GUARD="${WORKDIR}/bin/fake-feed-guard.sh"
cat > "${FAKE_FEED_GUARD}" <<'EOF'
#!/bin/sh
echo "$*" >> "${FEED_GUARD_LOG}"
cmd="$1"; shift
case "${cmd}" in
    check-monotonic)
        exit "${FAKE_MONOTONIC_RC:-0}"
        ;;
    plan-retention)
        printf '%s' "${FAKE_RETENTION_JSON:-[\"placeholder.apk\"]}"
        exit 0
        ;;
    *)
        echo "fake-feed-guard: unknown subcommand ${cmd}" >&2
        exit 9
        ;;
esac
EOF
chmod +x "${FAKE_FEED_GUARD}"

# --- stub curl (only the sign POST matters for these tests; the
# retained-blob GET branch is never reached because plan-retention above
# always returns just the filename already present in ARCH_DIR) ------------
#
# FIX3 test support: publish-arch.sh now passes the bearer token via
# `-H @<headerfile>`, and deletes that headerfile immediately after the
# curl call returns -- so by the time a test script could inspect it, it's
# already gone. This stub instead copies the referenced headerfile's
# CONTENT to AUTH_HEADER_LOG (a separate log path) at call time, while it
# still exists, so the test can assert on it afterward.
#
# FIX4 test support: FAKE_CURL_POST_RC lets a test force the sign POST to
# fail (simulating a 401/5xx curl -f failure) before any signature content
# is ever produced.
FAKE_CURL_DIR="${WORKDIR}/bin"
cat > "${FAKE_CURL_DIR}/curl" <<'EOF'
#!/bin/sh
echo "$*" >> "${CURL_LOG}"

OUT_FILE=""
prev=""
for a in "$@"; do
    case "${prev}" in
        -o) OUT_FILE="${a}" ;;
    esac
    case "${a}" in
        @*) [ -n "${AUTH_HEADER_LOG:-}" ] && cat "${a#@}" >> "${AUTH_HEADER_LOG}" ;;
    esac
    prev="${a}"
done

case " $* " in
    *" -X POST "*)
        if [ "${FAKE_CURL_POST_RC:-0}" != "0" ]; then
            exit "${FAKE_CURL_POST_RC}"
        fi
        BODY='{"signature":"'"$(printf 'FAKESIG' | base64 -w0)"'"}'
        if [ -n "${OUT_FILE}" ]; then
            printf '%s' "${BODY}" > "${OUT_FILE}"
        else
            printf '%s' "${BODY}"
        fi
        ;;
    *)
        exit 22
        ;;
esac
EOF
chmod +x "${FAKE_CURL_DIR}/curl"

# Common env for every stubbed invocation below.
export APK_BIN="${FAKE_APK}"
export ADB_SIGN_PY="${FAKE_ADB_SIGN}"
export FEED_GUARD="${FAKE_FEED_GUARD}"
export PUBKEY_PATH="${PUBKEY}"
export PATH="${WORKDIR}/bin:${PATH}"

run_publish() {
    # run_publish <log-prefix> [publish-arch.sh args...] -- captures
    # stdout+stderr to WORKDIR/<prefix>.log and prints the exit code.
    _prefix="$1"; shift
    if "${PUBLISH_ARCH}" "$@" >"${WORKDIR}/${_prefix}.log" 2>&1; then
        echo 0
    else
        echo "$?"
    fi
}

# ===========================================================================
# 1. usage / arg-handling errors
# ===========================================================================
echo "=== 1. usage / arg-handling errors ==="

SRC_APK_BASENAME=$(basename "${SRC_APK}")

RC=$(run_publish "no-args")
assert_eq "no args: exit non-zero" "true" "$([ "${RC}" -ne 0 ] && echo true || echo false)"
assert_contains "no args: usage message" "$(cat "${WORKDIR}/no-args.log")" "usage"

RC=$(run_publish "two-args" "aarch64_cortex-a53" "${SRC_APK}")
assert_eq "only 2 of 4 required args: exit non-zero" "true" "$([ "${RC}" -ne 0 ] && echo true || echo false)"

RC=$(run_publish "three-args" "aarch64_cortex-a53" "${SRC_APK}" "${SRC_APK_BASENAME}")
assert_eq "only 3 of 4 required args: exit non-zero" "true" "$([ "${RC}" -ne 0 ] && echo true || echo false)"

RC=$(run_publish "bad-flag" "aarch64_cortex-a53" "${SRC_APK}" "${SRC_APK_BASENAME}" "${WORKDIR}/pages-root" "--bogus")
assert_eq "unknown flag: exit non-zero" "true" "$([ "${RC}" -ne 0 ] && echo true || echo false)"
assert_contains "unknown flag: names the bad argument" "$(cat "${WORKDIR}/bad-flag.log")" "unknown argument"

RC=$(run_publish "missing-apk" "aarch64_cortex-a53" "${WORKDIR}/does-not-exist.apk" "${SRC_APK_BASENAME}" "${WORKDIR}/pages-root")
assert_eq "missing apk file: exit non-zero" "true" "$([ "${RC}" -ne 0 ] && echo true || echo false)"
assert_contains "missing apk file: names the cause" "$(cat "${WORKDIR}/missing-apk.log")" "apk file not found"

# FIX1: <published-filename> is now a required, validated argument in its
# own right (not derived from the apk file's basename) -- empty or
# path-separator-containing values must be rejected explicitly rather than
# silently accepted and later mis-copied.
RC=$(run_publish "empty-published-name" "aarch64_cortex-a53" "${SRC_APK}" "" "${WORKDIR}/pages-root")
assert_eq "empty published filename: exit non-zero" "true" "$([ "${RC}" -ne 0 ] && echo true || echo false)"
assert_contains "empty published filename: names the cause" "$(cat "${WORKDIR}/empty-published-name.log")" "published filename must not be empty"

RC=$(run_publish "slash-published-name" "aarch64_cortex-a53" "${SRC_APK}" "sub/dir/evil.apk" "${WORKDIR}/pages-root")
assert_eq "published filename with a path separator: exit non-zero" "true" "$([ "${RC}" -ne 0 ] && echo true || echo false)"
assert_contains "published filename with a path separator: names the cause" "$(cat "${WORKDIR}/slash-published-name.log")" "path separator"

RC=$(PUBKEY_PATH="${WORKDIR}/does-not-exist.pem" run_publish "missing-pubkey" "aarch64_cortex-a53" "${SRC_APK}" "${SRC_APK_BASENAME}" "${WORKDIR}/pages-root")
assert_eq "missing pubkey: exit non-zero" "true" "$([ "${RC}" -ne 0 ] && echo true || echo false)"
assert_contains "missing pubkey: names the cause" "$(cat "${WORKDIR}/missing-pubkey.log")" "pubkey not found"

echo

# ===========================================================================
# 2. happy path
# ===========================================================================
echo "=== 2. happy path (fully stubbed pipeline) ==="

PAGES_ROOT="${WORKDIR}/pages-root-ok"
FEED_GUARD_LOG="${WORKDIR}/feed-guard-ok.log"
CURL_LOG="${WORKDIR}/curl-ok.log"
AUTH_HEADER_LOG="${WORKDIR}/auth-header-ok.log"
: > "${FEED_GUARD_LOG}"
: > "${CURL_LOG}"
: > "${AUTH_HEADER_LOG}"

RC=$(FEED_GUARD_LOG="${FEED_GUARD_LOG}" CURL_LOG="${CURL_LOG}" AUTH_HEADER_LOG="${AUTH_HEADER_LOG}" \
     FAKE_MONOTONIC_RC=0 FAKE_VERIFY_RESULT=VALID FAKE_RETENTION_JSON='["tailscale-1.99.0-r1.apk"]' \
     IMPRIMATUR_AUTH_TOKEN="test-token-123" \
     run_publish "happy" "aarch64_cortex-a53" "${SRC_APK}" "${SRC_APK_BASENAME}" "${PAGES_ROOT}")
assert_eq "happy path: exit 0" "0" "${RC}"

ARCH_DIR="${PAGES_ROOT}/apk/aarch64_cortex-a53"
assert_eq "happy path: apk copied to arch dir under the published filename" "true" \
    "$([ -f "${ARCH_DIR}/tailscale-1.99.0-r1.apk" ] && echo true || echo false)"
assert_eq "happy path: packages.adb written" "true" \
    "$([ -f "${ARCH_DIR}/packages.adb" ] && echo true || echo false)"
assert_contains "happy path: packages.adb contains the (stubbed) signed marker" \
    "$(cat "${ARCH_DIR}/packages.adb" 2>/dev/null)" "SIGNED-OK"
assert_eq "happy path: retained.json written" "true" \
    "$([ -f "${ARCH_DIR}/retained.json" ] && echo true || echo false)"
assert_contains "happy path: retained.json has the planned content" \
    "$(cat "${ARCH_DIR}/retained.json")" "tailscale-1.99.0-r1.apk"

assert_eq "happy path: unsigned.adb scratch file cleaned up" "false" \
    "$([ -f "${ARCH_DIR}/unsigned.adb" ] && echo true || echo false)"
assert_eq "happy path: preimage.bin scratch file cleaned up" "false" \
    "$([ -f "${ARCH_DIR}/preimage.bin" ] && echo true || echo false)"
assert_eq "happy path: sig.der scratch file cleaned up" "false" \
    "$([ -f "${ARCH_DIR}/sig.der" ] && echo true || echo false)"
assert_eq "happy path: sign-response.json scratch file cleaned up" "false" \
    "$([ -f "${ARCH_DIR}/sign-response.json" ] && echo true || echo false)"

assert_contains "happy path: feed-guard.sh was called for check-monotonic" \
    "$(cat "${FEED_GUARD_LOG}")" "check-monotonic"
assert_contains "happy path: feed-guard.sh was called for plan-retention" \
    "$(cat "${FEED_GUARD_LOG}")" "plan-retention"

echo

# ===========================================================================
# 2b. FIX1: explicit published filename differs from the source basename
# ===========================================================================
echo "=== 2b. FIX1: published filename overrides the source apk's own basename ==="

PAGES_ROOT_RENAME="${WORKDIR}/pages-root-rename"
FEED_GUARD_LOG_RENAME="${WORKDIR}/feed-guard-rename.log"
CURL_LOG_RENAME="${WORKDIR}/curl-rename.log"
: > "${FEED_GUARD_LOG_RENAME}"
: > "${CURL_LOG_RENAME}"

# Mimics the republish-feed scenario: the source file on disk carries an
# arch suffix (as release-apk-assets names its loose release assets), but
# the feed convention wants it published WITHOUT that suffix -- previously
# only achievable via a rename/copy side-pipeline in the caller; now just an
# explicit argument.
PUBLISHED_NAME="tailscale-1.99.0-r1.apk"
RC=$(FEED_GUARD_LOG="${FEED_GUARD_LOG_RENAME}" CURL_LOG="${CURL_LOG_RENAME}" \
     FAKE_MONOTONIC_RC=0 FAKE_VERIFY_RESULT=VALID FAKE_RETENTION_JSON="[\"${PUBLISHED_NAME}\"]" \
     run_publish "rename" "aarch64_cortex-a53" "${SRC_APK_ARCHSUFFIXED}" "${PUBLISHED_NAME}" "${PAGES_ROOT_RENAME}")
assert_eq "differing published name: exit 0" "0" "${RC}"

ARCH_DIR_RENAME="${PAGES_ROOT_RENAME}/apk/aarch64_cortex-a53"
assert_eq "differing published name: file lands under the PUBLISHED name" "true" \
    "$([ -f "${ARCH_DIR_RENAME}/${PUBLISHED_NAME}" ] && echo true || echo false)"
assert_eq "differing published name: source (arch-suffixed) basename NOT used on disk" "false" \
    "$([ -f "${ARCH_DIR_RENAME}/$(basename "${SRC_APK_ARCHSUFFIXED}")" ] && echo true || echo false)"

echo

# ===========================================================================
# 3. H3/FIX3: imprimatur bearer-token auth header, sent WITHOUT touching argv
# ===========================================================================
echo "=== 3. H3/FIX3: Authorization: Bearer <token> sent via -H @<file>, never on argv ==="

assert_contains "auth-header-file content shows the Authorization: Bearer header with the real token" \
    "$(cat "${AUTH_HEADER_LOG}")" "Authorization: Bearer test-token-123"
assert_not_contains "curl argv log does NOT contain the raw token (FIX3: no argv exposure)" \
    "$(cat "${CURL_LOG}")" "test-token-123"
assert_contains "curl argv log shows the -H @<file> form was used" \
    "$(cat "${CURL_LOG}")" "-H @"

# Backward-compatible: an empty/unset token must not break the call (just an
# empty bearer) -- imprimatur ignores auth until its own env enables it.
PAGES_ROOT_NOTOK="${WORKDIR}/pages-root-notoken"
FEED_GUARD_LOG2="${WORKDIR}/feed-guard-notoken.log"
CURL_LOG2="${WORKDIR}/curl-notoken.log"
AUTH_HEADER_LOG2="${WORKDIR}/auth-header-notoken.log"
: > "${FEED_GUARD_LOG2}"
: > "${CURL_LOG2}"
: > "${AUTH_HEADER_LOG2}"
RC=$(FEED_GUARD_LOG="${FEED_GUARD_LOG2}" CURL_LOG="${CURL_LOG2}" AUTH_HEADER_LOG="${AUTH_HEADER_LOG2}" \
     FAKE_MONOTONIC_RC=0 FAKE_VERIFY_RESULT=VALID FAKE_RETENTION_JSON='["tailscale-1.99.0-r1.apk"]' \
     run_publish "notoken" "aarch64_cortex-a53" "${SRC_APK}" "${SRC_APK_BASENAME}" "${PAGES_ROOT_NOTOK}")
assert_eq "empty IMPRIMATUR_AUTH_TOKEN: still succeeds (backward-compatible)" "0" "${RC}"
assert_contains "empty token still sends a (harmless empty) Bearer header" \
    "$(cat "${AUTH_HEADER_LOG2}")" "Authorization: Bearer "

echo

# ===========================================================================
# 4. H7 hard gate (RED proof): a bad post-assemble verify aborts BEFORE
#    feed-guard.sh is ever invoked
# ===========================================================================
echo "=== 4. H7 hard gate: forced verify failure blocks publish, never reaches feed-guard ==="

PAGES_ROOT_BADSIG="${WORKDIR}/pages-root-badsig"
FEED_GUARD_LOG3="${WORKDIR}/feed-guard-badsig.log"
CURL_LOG3="${WORKDIR}/curl-badsig.log"
: > "${FEED_GUARD_LOG3}"
: > "${CURL_LOG3}"

RC=$(FEED_GUARD_LOG="${FEED_GUARD_LOG3}" CURL_LOG="${CURL_LOG3}" \
     FAKE_MONOTONIC_RC=0 FAKE_VERIFY_RESULT=INVALID \
     run_publish "badsig" "aarch64_cortex-a53" "${SRC_APK}" "${SRC_APK_BASENAME}" "${PAGES_ROOT_BADSIG}")
assert_eq "forced bad signature: exit non-zero (fail closed)" "true" \
    "$([ "${RC}" -ne 0 ] && echo true || echo false)"
assert_contains "forced bad signature: names the H7 gate as the cause" \
    "$(cat "${WORKDIR}/badsig.log")" "verification FAILED"
assert_eq "forced bad signature: feed-guard.sh was NEVER called (gate runs before monotonicity/deploy)" "" \
    "$(cat "${FEED_GUARD_LOG3}")"

echo

# ===========================================================================
# 5. monotonicity rejection propagates and short-circuits before retention
# ===========================================================================
echo "=== 5. monotonicity guard rejection propagates, never reaches plan-retention ==="

PAGES_ROOT_MONO="${WORKDIR}/pages-root-mono"
FEED_GUARD_LOG4="${WORKDIR}/feed-guard-mono.log"
CURL_LOG4="${WORKDIR}/curl-mono.log"
: > "${FEED_GUARD_LOG4}"
: > "${CURL_LOG4}"

RC=$(FEED_GUARD_LOG="${FEED_GUARD_LOG4}" CURL_LOG="${CURL_LOG4}" \
     FAKE_MONOTONIC_RC=1 FAKE_VERIFY_RESULT=VALID \
     run_publish "mono-reject" "aarch64_cortex-a53" "${SRC_APK}" "${SRC_APK_BASENAME}" "${PAGES_ROOT_MONO}")
assert_eq "monotonicity guard rejects: publish-arch.sh propagates the failure (exit non-zero)" "true" \
    "$([ "${RC}" -ne 0 ] && echo true || echo false)"
assert_contains "monotonicity guard rejects: feed-guard.sh WAS called for check-monotonic" \
    "$(cat "${FEED_GUARD_LOG4}")" "check-monotonic"
assert_not_contains "monotonicity guard rejects: plan-retention was NEVER reached" \
    "$(cat "${FEED_GUARD_LOG4}")" "plan-retention"
assert_eq "monotonicity guard rejects: retained.json was never written" "false" \
    "$([ -f "${PAGES_ROOT_MONO}/apk/aarch64_cortex-a53/retained.json" ] && echo true || echo false)"

echo

# ===========================================================================
# 6. --force forwarding to feed-guard.sh check-monotonic
# ===========================================================================
echo "=== 6. --force is forwarded to check-monotonic exactly when passed ==="

PAGES_ROOT_FORCE="${WORKDIR}/pages-root-force"
FEED_GUARD_LOG5="${WORKDIR}/feed-guard-force.log"
CURL_LOG5="${WORKDIR}/curl-force.log"
: > "${FEED_GUARD_LOG5}"
: > "${CURL_LOG5}"

RC=$(FEED_GUARD_LOG="${FEED_GUARD_LOG5}" CURL_LOG="${CURL_LOG5}" \
     FAKE_MONOTONIC_RC=0 FAKE_VERIFY_RESULT=VALID FAKE_RETENTION_JSON='["tailscale-1.99.0-r1.apk"]' \
     run_publish "force" "aarch64_cortex-a53" "${SRC_APK}" "${SRC_APK_BASENAME}" "${PAGES_ROOT_FORCE}" "--force")
assert_eq "--force run: exit 0" "0" "${RC}"
CHECK_LINE=$(grep '^check-monotonic' "${FEED_GUARD_LOG5}" || true)
assert_contains "--force: forwarded onto the check-monotonic invocation" "${CHECK_LINE}" "--force"

# And the no-force happy-path run from section 2 must NOT have forwarded it.
NOFORCE_LINE=$(grep '^check-monotonic' "${FEED_GUARD_LOG}" || true)
assert_not_contains "no --force given: NOT forwarded onto check-monotonic" "${NOFORCE_LINE}" "--force"

echo

# ===========================================================================
# 7. FIX4 (RED proof): a sign-POST curl failure aborts loudly and
#    immediately -- never silently falls through to the empty/null
#    signature check, and never reaches assemble/packages.adb.
# ===========================================================================
echo "=== 7. FIX4: sign-POST curl failure aborts loudly, never produces packages.adb ==="

PAGES_ROOT_CURLFAIL="${WORKDIR}/pages-root-curlfail"
FEED_GUARD_LOG6="${WORKDIR}/feed-guard-curlfail.log"
CURL_LOG6="${WORKDIR}/curl-curlfail.log"
: > "${FEED_GUARD_LOG6}"
: > "${CURL_LOG6}"

RC=$(FEED_GUARD_LOG="${FEED_GUARD_LOG6}" CURL_LOG="${CURL_LOG6}" \
     FAKE_CURL_POST_RC=22 \
     run_publish "curlfail" "aarch64_cortex-a53" "${SRC_APK}" "${SRC_APK_BASENAME}" "${PAGES_ROOT_CURLFAIL}")
assert_eq "sign-POST curl failure: exit non-zero" "true" \
    "$([ "${RC}" -ne 0 ] && echo true || echo false)"
assert_contains "sign-POST curl failure: names curl (not a signature-content complaint) as the cause" \
    "$(cat "${WORKDIR}/curlfail.log")" "curl error"
assert_eq "sign-POST curl failure: packages.adb never written" "false" \
    "$([ -f "${PAGES_ROOT_CURLFAIL}/apk/aarch64_cortex-a53/packages.adb" ] && echo true || echo false)"
assert_eq "sign-POST curl failure: feed-guard.sh NEVER called (fails before monotonicity/deploy)" "" \
    "$(cat "${FEED_GUARD_LOG6}")"

harness_finish "tests/apk/publish-arch.sh"
