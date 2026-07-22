#!/bin/sh
# tests/apk/fpu-sigill-smoke.sh
#
# Slice S7a D3/D5 (RFC docs/rfc-apk-arch-coverage.md §5.6): the FPU-SIGILL
# spike, moved here from S6. Question: can qemu-user actually SIGILL a
# wrongly-hardfloat ARM binary on an FPU-less CPU model, so the softfloat
# assignments this repo depends on (bare arm_cortex-a7/-a9 -> GOARM=5, the
# live §9 bug fix) are REGRESSION-GUARDED, not just "correct by inspection"?
#
# CONFIRMED (S7a handoff notes): qemu-arm -- specifically the build shipped
# by tonistiigi/binfmt (what `docker/setup-qemu-action@v3` actually
# registers in CI) -- cleanly raises SIGILL ("uncaught target signal 4",
# exit 128+4=132) when executing a GOARM=7 (hardfloat/VFP) Go ARM binary
# under an FPU-less CPU model (arm926/arm946/arm1176, or cortex-a7 with
# vfp explicitly disabled). The SAME binary under a VFP-equipped model
# (cortex-a9) runs fine -- isolating the failure to FPU absence, not a
# broken harness. NOTE: the OLDER multiarch/qemu-user-static build (this
# repo's OWN local-dev register_standard_qemu_binfmt helper) does NOT
# reproduce this cleanly -- it HANGS instead of signaling -- so this test
# invokes tonistiigi/binfmt's qemu-arm DIRECTLY (extracted via `docker cp`,
# no `docker run`/binfmt_misc indirection at all), sidestepping that
# discrepancy entirely rather than depending on whichever binfmt_misc
# registration happens to be live on the host.
#
# Guarded behind FPU_SIGILL_SMOKE=1 (mirrors the opt-in convention used
# elsewhere for a heavier, real docker-dependent proof, e.g. apk-matrix.sh's
# --build flag) -- SKIPPED by default so it doesn't add docker-pull +
# compile cost to a routine local run; the CI workflow sets the flag
# explicitly (a dedicated, non-matrixed job -- this proves qemu's OWN
# capability, not a specific arch, so it runs once, not per verify_families
# leg).
#
# Usage:
#   FPU_SIGILL_SMOKE=1 sh tests/apk/fpu-sigill-smoke.sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# shellcheck source=tests/apk/lib.sh
. "${SCRIPT_DIR}/lib.sh"

if [ "${FPU_SIGILL_SMOKE:-0}" != "1" ]; then
    echo "FPU_SIGILL_SMOKE!=1: skipping (opt-in spike proof -- set FPU_SIGILL_SMOKE=1 to run; the CI workflow does)"
    exit 0
fi

require_cmd docker

WORKDIR=$(mktemp -d)
trap 'rm -rf "${WORKDIR}"' EXIT

echo "=== building tiny fixture ARM binaries (GOARM=7 hardfloat + GOARM=5 softfloat) ==="

cat > "${WORKDIR}/main.go" <<'EOF'
package main

import (
	"fmt"
	"os"
	"strconv"
)

// Reads the LAST two args (not a fixed os.Args[1]/[2]) -- deliberate:
// qemu-arm invoked DIRECTLY (bypassing binfmt_misc, see the header comment
// on why) does not always synthesize argv[0] as the target's own program
// path the way an execve()-launched process would, so os.Args' exact
// length/offset is qemu-invocation-dependent. Only the trailing two
// argument VALUES matter for this fixture's floating-point smoke check.
func main() {
	n := len(os.Args)
	x, _ := strconv.ParseFloat(os.Args[n-2], 64)
	y, _ := strconv.ParseFloat(os.Args[n-1], 64)
	fmt.Println(x * y / (x + y))
}
EOF

if ! docker run --rm -v "${WORKDIR}:/src" -w /src -e CGO_ENABLED=0 -e GOOS=linux -e GOARCH=arm -e GOARM=7 \
        golang:1.24-alpine go build -o fpu-hard-vfp main.go >&2; then
    log_fail "failed to cross-compile the GOARM=7 (hardfloat) fixture binary"
    harness_finish "tests/apk/fpu-sigill-smoke.sh"
    exit "${FAIL}"
fi

if ! docker run --rm -v "${WORKDIR}:/src" -w /src -e CGO_ENABLED=0 -e GOOS=linux -e GOARCH=arm -e GOARM=5 \
        golang:1.24-alpine go build -o fpu-soft main.go >&2; then
    log_fail "failed to cross-compile the GOARM=5 (softfloat) fixture binary"
    harness_finish "tests/apk/fpu-sigill-smoke.sh"
    exit "${FAIL}"
fi

echo "=== extracting tonistiigi/binfmt's qemu-arm (the emulator docker/setup-qemu-action@v3 actually registers) ==="

CID=$(docker create tonistiigi/binfmt)
docker cp "${CID}:/usr/bin/qemu-arm" "${WORKDIR}/qemu-arm"
docker rm -f "${CID}" >/dev/null 2>&1 || true
chmod +x "${WORKDIR}/qemu-arm"

echo

# run_qemu_arm cpu binary args... -- direct invocation (no docker run/binfmt
# indirection), captures combined output + exit code without tripping
# `set -e`.
run_qemu_arm() {
    _cpu="$1"; shift
    _bin="$1"; shift
    _out=$(timeout -k 2 10 "${WORKDIR}/qemu-arm" -cpu "${_cpu}" "${_bin}" "$@" 2>&1 </dev/null)
    _rc=$?
    printf '%s' "${_out}"
    return "${_rc}"
}

echo "=== THE SPIKE: qemu-arm SIGILLs a hardfloat (GOARM=7) binary on FPU-less CPU models ==="

for cpu in arm926 arm946 arm1176 "cortex-a7,vfp=off"; do
    set +e
    OUT=$(run_qemu_arm "${cpu}" "${WORKDIR}/fpu-hard-vfp" 6 3)
    RC=$?
    set -e
    if [ "${RC}" -eq 132 ] || [ "${RC}" -eq 4 ]; then
        log_info "OK: cpu=${cpu}: hardfloat binary SIGILLs cleanly (exit ${RC}: ${OUT})"
    else
        log_fail "cpu=${cpu}: expected a clean SIGILL (exit 132) for the hardfloat binary, got exit ${RC}: ${OUT}"
    fi
done

echo

echo "=== sanity: the SAME hardfloat binary runs fine on a VFP-equipped CPU model ==="

set +e
VFP_OUT=$(run_qemu_arm cortex-a9 "${WORKDIR}/fpu-hard-vfp" 6 3)
VFP_RC=$?
set -e
assert_eq "cortex-a9 (has VFP): hardfloat binary exits 0" "0" "${VFP_RC}"
assert_eq "cortex-a9 (has VFP): hardfloat binary computes 6*3/(6+3)=2" "2" "${VFP_OUT}"

echo

echo "=== sanity: the softfloat binary runs fine on an FPU-less CPU model (isolates the failure to FPU absence) ==="

set +e
SOFT_OUT=$(run_qemu_arm arm926 "${WORKDIR}/fpu-soft" 6 3)
SOFT_RC=$?
set -e
assert_eq "arm926 (no VFP): softfloat binary exits 0" "0" "${SOFT_RC}"
assert_eq "arm926 (no VFP): softfloat binary computes 6*3/(6+3)=2" "2" "${SOFT_OUT}"

harness_finish "tests/apk/fpu-sigill-smoke.sh"
