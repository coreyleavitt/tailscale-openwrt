#!/bin/sh
# tests/apk/compile-smoke.sh
#
# Slice S2 compile-smoke test (RFC docs/rfc-apk-arch-coverage.md §5.1/§5.6
# M1/S2): cross-compilation needs no qemu (it runs on the amd64 host
# regardless of target), so this is cheap and distinct from the S7a
# qemu-boot verify spikes. For EVERY one of the 14 family build tuples
# (derived the same way scripts/arches.sh's --id-for groups them --
# goarch/goarm/gomips/gomips64/go386), this:
#   1. `docker build --target build` with SKIP_UPX=1 and all five build-arg
#      fields sourced from arches.json (no name-based derivation -- see the
#      Dockerfile's `build` stage, RFC §5.1/S2);
#   2. extracts /build/tailscaled and runs `readelf -h` on it;
#   3. asserts the ELF machine type matches what that family's goarch
#      should cross-compile to (AArch64/ARM/MIPS R3000/Intel 80386/x86-64/
#      RISC-V/LoongArch) -- a real, empirical check that the explicit
#      build-arg wiring actually reaches `go build` and produces the right
#      binary, not just that arches.json/build-apk.sh *say* it should.
#
# loong64 in particular has no Tailscale-official prior art (Tailscale
# doesn't ship it upstream; riscv64/mips64 they do) -- see RFC §5.6 M1 --
# so this is the only thing that empirically proves loong64 cross-compiles
# at all before S3/S4 start publishing it.
#
# COST CONTROL: this script is written to iterate ALL 14 families by
# default (so CI can run the full set), but a real local invocation should
# NOT build all 14 -- pass a representative subset via
# COMPILE_SMOKE_FAMILIES (space-separated family ids, e.g.
# "A64 ASOFT M32BE M32LE LOONG64 RV64 M64BE"). See the RFC's own guidance:
# the 4 legacy core families (A64/ASOFT/M32BE/M32LE) plus the
# cross-compile-risk novel families (LOONG64/RV64/M64BE, i.e. 64-bit
# targets never built by this repo before) -- 7 builds total.
#
# Representative arch NAME per family: the family's `core`-tier arch if one
# exists (so the legacy 4 families smoke-test the EXACT arch name production
# uses), else the lexicographically-first arch sharing that build tuple
# (deterministic, content-derived, mirrors arches.sh --with-ci's own
# tie-break rule).
#
# Usage:
#   sh tests/apk/compile-smoke.sh                    # all 14 families (CI)
#   COMPILE_SMOKE_FAMILIES="A64 ASOFT M32BE M32LE LOONG64 RV64 M64BE" \
#     sh tests/apk/compile-smoke.sh                   # representative subset (local)

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
PKG_DIR="${REPO_ROOT}/tailscale-package"
ARCHES_JSON="${REPO_ROOT}/arches.json"
ARCHES_SH="${REPO_ROOT}/scripts/arches.sh"

# shellcheck source=tests/apk/lib.sh
. "${SCRIPT_DIR}/lib.sh"

require_cmd docker
require_cmd jq
require_cmd readelf

if [ ! -f "${PKG_DIR}/Dockerfile" ]; then
    echo "FAIL: ${PKG_DIR}/Dockerfile not found" >&2
    exit 1
fi
if [ ! -f "${ARCHES_JSON}" ]; then
    echo "FAIL: ${ARCHES_JSON} not found" >&2
    exit 1
fi

TEST_VERSION="${COMPILE_SMOKE_TEST_VERSION:-1.92.2}"
TEST_PKG_RELEASE="${COMPILE_SMOKE_TEST_PKG_RELEASE:-1}"
ONLY_FAMILIES="${COMPILE_SMOKE_FAMILIES:-}"

WORKDIR=$(mktemp -d)
trap 'rm -rf "${WORKDIR}"' EXIT

# expected_machine goarch -- the readelf -h "Machine:" substring a
# cross-compile to this GOARCH must produce. EM_MIPS (mips/mipsle/mips64/
# mips64le) prints "MIPS R3000" regardless of 32/64-bit (binutils quirk --
# the ELF class field, ELF32 vs ELF64, is what actually distinguishes them,
# checked separately below for the 64-bit MIPS families).
expected_machine() {
    case "$1" in
        arm64) echo "AArch64" ;;
        arm) echo "ARM" ;;
        mips|mipsle|mips64|mips64le) echo "MIPS R3000" ;;
        386) echo "Intel 80386" ;;
        amd64) echo "Advanced Micro Devices X86-64" ;;
        riscv64) echo "RISC-V" ;;
        loong64) echo "LoongArch" ;;
        *) echo "" ;;
    esac
}

expected_class() {
    case "$1" in
        mips64|mips64le) echo "ELF64" ;;
        mips|mipsle) echo "ELF32" ;;
        *) echo "" ;;
    esac
}

# One row per family (14), representative arch = that family's core-tier
# arch if any, else the lexicographically-first arch sharing the tuple.
FAMILIES_JSON=$(jq -c '
    [.[] | select(.tier != "infeasible")]
    | group_by([.goarch, .goarm, .gomips, .gomips64, .go386])
    | map(
        . as $rows
        | ([$rows[] | select(.tier == "core")]) as $core
        | (if ($core | length) > 0 then $core[0] else ($rows | sort_by(.name))[0] end) as $rep
        | {name: $rep.name, goarch: $rep.goarch, goarm: $rep.goarm,
           gomips: $rep.gomips, gomips64: $rep.gomips64, go386: $rep.go386}
      )
    | sort_by(.name)
' "${ARCHES_JSON}")

FAMILY_COUNT=$(echo "${FAMILIES_JSON}" | jq 'length')
if [ "${FAMILY_COUNT}" -ne 14 ]; then
    log_fail "expected exactly 14 derived families, got ${FAMILY_COUNT}"
    harness_finish "tests/apk/compile-smoke.sh"
fi
log_info "OK: 14 family build tuples derived from arches.json"

if [ -n "${ONLY_FAMILIES}" ]; then
    echo "COST CONTROL: limiting to representative subset: ${ONLY_FAMILIES}"
else
    echo "Running the FULL 14-family compile-smoke (no COMPILE_SMOKE_FAMILIES override)"
fi

_i=0
_ran=0
while [ "${_i}" -lt "${FAMILY_COUNT}" ]; do
    _row=$(echo "${FAMILIES_JSON}" | jq -c ".[${_i}]")
    _i=$((_i + 1))

    _name=$(echo "${_row}" | jq -r '.name')
    _goarch=$(echo "${_row}" | jq -r '.goarch // ""')
    _goarm=$(echo "${_row}" | jq -r '.goarm // ""')
    _gomips=$(echo "${_row}" | jq -r '.gomips // ""')
    _gomips64=$(echo "${_row}" | jq -r '.gomips64 // ""')
    _go386=$(echo "${_row}" | jq -r '.go386 // ""')

    _family=$("${ARCHES_SH}" --id-for "${_goarch}" "${_goarm}" "${_gomips}" "${_gomips64}" "${_go386}") || {
        log_fail "arch '${_name}' has an unmapped build tuple (goarch=${_goarch} goarm=${_goarm} gomips=${_gomips} gomips64=${_gomips64} go386=${_go386})"
        continue
    }

    if [ -n "${ONLY_FAMILIES}" ]; then
        _skip=1
        for _f in ${ONLY_FAMILIES}; do
            [ "${_f}" = "${_family}" ] && _skip=0
        done
        if [ "${_skip}" -eq 1 ]; then
            echo "--- skipping family ${_family} (${_name}) -- not in COMPILE_SMOKE_FAMILIES ---"
            continue
        fi
    fi

    _ran=$((_ran + 1))
    echo ""
    echo "=== compile-smoke: family ${_family} (arch=${_name}, goarch=${_goarch} goarm=${_goarm} gomips=${_gomips} gomips64=${_gomips64} go386=${_go386}) ==="

    _family_lc=$(echo "${_family}" | tr 'A-Z' 'a-z')
    _tag="tailscale-compile-smoke-${_family_lc}:test"
    _log="${WORKDIR}/${_family}.build.log"

    if ! docker build \
        --progress=plain \
        --target build \
        --build-arg TAILSCALE_VERSION="${TEST_VERSION}" \
        --build-arg PKG_RELEASE="${TEST_PKG_RELEASE}" \
        --build-arg OPENWRT_ARCH="${_name}" \
        --build-arg GOARCH="${_goarch}" \
        --build-arg GOARM="${_goarm}" \
        --build-arg GOMIPS="${_gomips}" \
        --build-arg GOMIPS64="${_gomips64}" \
        --build-arg GO386="${_go386}" \
        --build-arg SKIP_UPX=1 \
        -t "${_tag}" \
        -f "${PKG_DIR}/Dockerfile" "${PKG_DIR}" >"${_log}" 2>&1; then
        tail -n 40 "${_log}" >&2
        log_fail "family ${_family} (${_name}): docker build failed -- see ${_log}"
        continue
    fi

    _cid=$(docker create "${_tag}")
    _bin="${WORKDIR}/${_family}.tailscaled"
    docker cp "${_cid}:/build/tailscaled" "${_bin}" >/dev/null
    docker rm -f "${_cid}" >/dev/null 2>&1 || true

    if [ ! -s "${_bin}" ]; then
        log_fail "family ${_family} (${_name}): /build/tailscaled missing/empty after extraction"
        docker rmi "${_tag}" >/dev/null 2>&1 || true
        continue
    fi

    _readelf=$(readelf -h "${_bin}")
    _machine=$(echo "${_readelf}" | grep -m1 'Machine:' | sed 's/.*Machine:[[:space:]]*//')
    _class=$(echo "${_readelf}" | grep -m1 'Class:' | sed 's/.*Class:[[:space:]]*//')

    _expect_machine=$(expected_machine "${_goarch}")
    if [ -n "${_expect_machine}" ]; then
        assert_eq "family ${_family} (${_name}): ELF machine" "${_expect_machine}" "${_machine}"
    else
        log_fail "family ${_family} (${_name}): no expected-machine mapping for goarch '${_goarch}'"
    fi

    _expect_class=$(expected_class "${_goarch}")
    if [ -n "${_expect_class}" ]; then
        assert_eq "family ${_family} (${_name}): ELF class" "${_expect_class}" "${_class}"
    fi

    log_info "OK: family ${_family} (${_name}) -> $(du -h "${_bin}" | cut -f1) ELF (${_class}, ${_machine})"

    docker rmi "${_tag}" >/dev/null 2>&1 || true
done

if [ "${_ran}" -eq 0 ]; then
    log_fail "no families were actually built -- COMPILE_SMOKE_FAMILIES matched nothing"
fi

echo ""
echo "compile-smoke: ${_ran}/${FAMILY_COUNT} families built"

harness_finish "tests/apk/compile-smoke.sh"
