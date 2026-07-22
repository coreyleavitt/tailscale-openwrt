#!/bin/sh
# tests/apk/stage-payload.sh
#
# Regression test for scripts/stage-payload.sh's named-flag interface
# (RFC docs/rfc-apk-arch-coverage.md handoff L4 code-review finding):
# stage-payload.sh used to take three POSITIONAL path args (<src-dir>
# <dest-root> <binary-path>) -- the exact transposable-positional-args
# class of bug scripts/package-apk.sh was already redesigned off of (see
# that script's own header note, "Named flags, not positionals (RFC
# round-2 D-SEV3)"). stage-payload.sh is converted here to named flags
# (--src-dir/--dest-root/--binary), mirroring package-apk.sh's convention
# exactly, and this test asserts:
#   1. the new named-flag form stages the full on-device tree correctly
#      (paths + modes) -- a fast, no-docker fixture-driven check (no
#      compiled binary/tailscale source needed, unlike the docker-backed
#      tests/apk/mkpkg.sh, which exercises stage-payload.sh transitively
#      through scripts/package-apk.sh and stays the behavioral/integration
#      check for the real payload).
#   2. an unknown flag hard-fails with a non-zero exit.
#   3. a missing required flag hard-fails with a non-zero exit.
#   4. the OLD positional form (three bare args, no flags) is REJECTED --
#      a regression guard against silently reintroducing the
#      transposable-positional interface this slice removes.
#
# No docker required. Usage: sh tests/apk/stage-payload.sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
STAGE_PAYLOAD="${REPO_ROOT}/scripts/stage-payload.sh"

# shellcheck source=tests/apk/lib.sh
. "${SCRIPT_DIR}/lib.sh"

if [ ! -f "${STAGE_PAYLOAD}" ]; then
    echo "FAIL: ${STAGE_PAYLOAD} not found" >&2
    exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "${WORKDIR}"' EXIT

# --- fixture: a minimal src-dir with all 9 required source files, plus a
# stand-in "compiled binary" file (stage-payload.sh only checks it exists
# as a regular file -- it doesn't need to be a real ELF for this test).
SRC_DIR="${WORKDIR}/src"
mkdir -p "${SRC_DIR}"
for _f in tailscale.init tailscale.config tailscale-wrapper.sh \
          tailscale-killswitch.sh tailscale-killswitch-boot.sh \
          tailscale-exitnode.sh tailscale-setup.sh \
          luci-protocol-tailscale.js tailscale.keep; do
    echo "fixture-${_f}" > "${SRC_DIR}/${_f}"
done

BINARY="${WORKDIR}/tailscaled-fixture"
echo "fixture-binary" > "${BINARY}"

# --- 1. named-flag form stages the tree correctly ------------------------
DEST_ROOT="${WORKDIR}/dest"
if sh "${STAGE_PAYLOAD}" --src-dir "${SRC_DIR}" --dest-root "${DEST_ROOT}" --binary "${BINARY}" \
    >"${WORKDIR}/stage.log" 2>&1; then
    log_info "OK: named-flag invocation succeeded"
else
    log_fail "named-flag invocation failed -- see ${WORKDIR}/stage.log"
    cat "${WORKDIR}/stage.log" >&2
fi

assert_eq "usr/sbin/tailscaled staged" \
    "fixture-binary" "$(cat "${DEST_ROOT}/usr/sbin/tailscaled" 2>/dev/null || echo MISSING)"
assert_eq "etc/init.d/tailscale staged" \
    "fixture-tailscale.init" "$(cat "${DEST_ROOT}/etc/init.d/tailscale" 2>/dev/null || echo MISSING)"
assert_eq "usr/bin/tailscale staged" \
    "fixture-tailscale-wrapper.sh" "$(cat "${DEST_ROOT}/usr/bin/tailscale" 2>/dev/null || echo MISSING)"
assert_eq "lib/upgrade/keep.d/tailscale staged" \
    "fixture-tailscale.keep" "$(cat "${DEST_ROOT}/lib/upgrade/keep.d/tailscale" 2>/dev/null || echo MISSING)"

assert_eq "usr/sbin/tailscaled mode" \
    "755" "$(stat -c %a "${DEST_ROOT}/usr/sbin/tailscaled" 2>/dev/null || echo MISSING)"
assert_eq "etc/config/tailscale mode" \
    "600" "$(stat -c %a "${DEST_ROOT}/etc/config/tailscale" 2>/dev/null || echo MISSING)"

# --- 2. unknown flag hard-fails -------------------------------------------
if sh "${STAGE_PAYLOAD}" --bogus-flag x --src-dir "${SRC_DIR}" --dest-root "${WORKDIR}/dest2" --binary "${BINARY}" \
    >"${WORKDIR}/unknown.log" 2>&1; then
    log_fail "unknown flag unexpectedly succeeded -- see ${WORKDIR}/unknown.log"
else
    log_info "OK: unknown flag hard-fails"
fi

# --- 3. missing required flag hard-fails ----------------------------------
if sh "${STAGE_PAYLOAD}" --src-dir "${SRC_DIR}" --binary "${BINARY}" \
    >"${WORKDIR}/missing.log" 2>&1; then
    log_fail "missing --dest-root unexpectedly succeeded -- see ${WORKDIR}/missing.log"
else
    log_info "OK: missing --dest-root hard-fails"
fi

# --- 4. regression guard: old positional form is rejected -----------------
if sh "${STAGE_PAYLOAD}" "${SRC_DIR}" "${WORKDIR}/dest3" "${BINARY}" \
    >"${WORKDIR}/positional.log" 2>&1; then
    log_fail "old positional-arg form unexpectedly succeeded (stage-payload.sh must reject bare positional args now that it takes named flags) -- see ${WORKDIR}/positional.log"
else
    log_info "OK: old positional-arg form is rejected"
fi

harness_finish "tests/apk/stage-payload.sh"
