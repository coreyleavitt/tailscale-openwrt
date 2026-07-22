#!/bin/sh
# tests/apk/legacy-identical.sh
#
# Slice S2 byte-identical test (RFC docs/rfc-apk-arch-coverage.md §5.1/S2):
# proves the GOARCH refactor (deleting the string-`case` derivation for an
# explicit --build-arg-driven one) does NOT change the compiled output for
# the 4 arches already in production (tier=="core"). For each core arch,
# builds `--target build` (real, WITH upx -- no SKIP_UPX) via TWO paths:
#
#   OLD path -- the pre-S2 Dockerfile, exactly as committed at git HEAD (S1
#     never touched the build stage, so `git show HEAD:tailscale-package/
#     Dockerfile` is genuinely the pre-refactor file), invoked the way the
#     OLD build-apk.sh called it: OPENWRT_ARCH + GOARM/GOMIPS build-args
#     only (no GOARCH -- the old Dockerfile derives it from OPENWRT_ARCH's
#     name).
#   NEW path -- the current working-tree Dockerfile, invoked the way the
#     NEW build-apk.sh calls it: all five build-tuple fields (GOARCH/GOARM/
#     GOMIPS/GOMIPS64/GO386) passed explicitly from arches.json.
#
# ...then sha256-compares the two /build/tailscaled binaries. If they are
# NOT byte-identical, falls back to the RFC's documented comparison mode:
# strip both with `go tool buildid -w` neutralization is unreliable across
# differently-sized ids, so instead this diffs the raw bytes (`cmp -l`) and
# reports whether the differing bytes are confined to a small, contiguous
# region (consistent with Go's embedded build-id, which is not part of the
# program's semantics) versus scattered throughout (which would indicate a
# real behavioral change and should be treated as a BLOCKER, not a benign
# delta).
#
# Usage: sh tests/apk/legacy-identical.sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
PKG_DIR="${REPO_ROOT}/tailscale-package"
ARCHES_JSON="${REPO_ROOT}/arches.json"

# shellcheck source=tests/apk/lib.sh
. "${SCRIPT_DIR}/lib.sh"

require_cmd docker
require_cmd jq
require_cmd git
require_cmd cmp

TEST_VERSION="${LEGACY_IDENTICAL_TEST_VERSION:-1.92.2}"
TEST_PKG_RELEASE="${LEGACY_IDENTICAL_TEST_PKG_RELEASE:-1}"

WORKDIR=$(mktemp -d)
trap 'rm -rf "${WORKDIR}"' EXIT

OLD_DOCKERFILE="${WORKDIR}/old.Dockerfile"
if ! git -C "${REPO_ROOT}" show HEAD:tailscale-package/Dockerfile > "${OLD_DOCKERFILE}" 2>/dev/null; then
    echo "FAIL: could not extract pre-S2 Dockerfile via 'git show HEAD:tailscale-package/Dockerfile'" >&2
    exit 1
fi

# Core arches (RFC §5.8 migration gate) -- the ones actually live today.
CORE_ARCHES=$(jq -r '.[] | select(.tier == "core") | .name' "${ARCHES_JSON}")

for ARCH in ${CORE_ARCHES}; do
    echo ""
    echo "=== legacy-identical: ${ARCH} ==="

    GOARCH=$(jq -r --arg n "${ARCH}" '.[] | select(.name==$n) | .goarch // ""' "${ARCHES_JSON}")
    GOARM=$(jq -r --arg n "${ARCH}" '.[] | select(.name==$n) | .goarm // ""' "${ARCHES_JSON}")
    GOMIPS=$(jq -r --arg n "${ARCH}" '.[] | select(.name==$n) | .gomips // ""' "${ARCHES_JSON}")
    GOMIPS64=$(jq -r --arg n "${ARCH}" '.[] | select(.name==$n) | .gomips64 // ""' "${ARCHES_JSON}")
    GO386=$(jq -r --arg n "${ARCH}" '.[] | select(.name==$n) | .go386 // ""' "${ARCHES_JSON}")

    OLD_TAG="tailscale-legacy-identical-old-${ARCH}:test"
    NEW_TAG="tailscale-legacy-identical-new-${ARCH}:test"
    OLD_LOG="${WORKDIR}/${ARCH}.old.log"
    NEW_LOG="${WORKDIR}/${ARCH}.new.log"

    echo "--- OLD path (pre-S2 Dockerfile, case-derived GOARCH) ---"
    if ! docker build \
        --progress=plain \
        --target build \
        --build-arg TAILSCALE_VERSION="${TEST_VERSION}" \
        --build-arg PKG_RELEASE="${TEST_PKG_RELEASE}" \
        --build-arg OPENWRT_ARCH="${ARCH}" \
        --build-arg GOARM="${GOARM}" \
        --build-arg GOMIPS="${GOMIPS}" \
        -t "${OLD_TAG}" \
        -f "${OLD_DOCKERFILE}" "${PKG_DIR}" >"${OLD_LOG}" 2>&1; then
        tail -n 40 "${OLD_LOG}" >&2
        log_fail "${ARCH}: OLD-path docker build failed -- see ${OLD_LOG}"
        continue
    fi

    echo "--- NEW path (post-S2 Dockerfile, explicit build-arg GOARCH) ---"
    if ! docker build \
        --progress=plain \
        --target build \
        --build-arg TAILSCALE_VERSION="${TEST_VERSION}" \
        --build-arg PKG_RELEASE="${TEST_PKG_RELEASE}" \
        --build-arg OPENWRT_ARCH="${ARCH}" \
        --build-arg GOARCH="${GOARCH}" \
        --build-arg GOARM="${GOARM}" \
        --build-arg GOMIPS="${GOMIPS}" \
        --build-arg GOMIPS64="${GOMIPS64}" \
        --build-arg GO386="${GO386}" \
        -t "${NEW_TAG}" \
        -f "${PKG_DIR}/Dockerfile" "${PKG_DIR}" >"${NEW_LOG}" 2>&1; then
        tail -n 40 "${NEW_LOG}" >&2
        log_fail "${ARCH}: NEW-path docker build failed -- see ${NEW_LOG}"
        continue
    fi

    OLD_CID=$(docker create "${OLD_TAG}")
    OLD_BIN="${WORKDIR}/${ARCH}.old.tailscaled"
    docker cp "${OLD_CID}:/build/tailscaled" "${OLD_BIN}" >/dev/null
    docker rm -f "${OLD_CID}" >/dev/null 2>&1 || true

    NEW_CID=$(docker create "${NEW_TAG}")
    NEW_BIN="${WORKDIR}/${ARCH}.new.tailscaled"
    docker cp "${NEW_CID}:/build/tailscaled" "${NEW_BIN}" >/dev/null
    docker rm -f "${NEW_CID}" >/dev/null 2>&1 || true

    if [ ! -s "${OLD_BIN}" ] || [ ! -s "${NEW_BIN}" ]; then
        log_fail "${ARCH}: OLD or NEW /build/tailscaled missing/empty after extraction"
        docker rmi "${OLD_TAG}" "${NEW_TAG}" >/dev/null 2>&1 || true
        continue
    fi

    OLD_SHA=$(sha256sum "${OLD_BIN}" | awk '{print $1}')
    NEW_SHA=$(sha256sum "${NEW_BIN}" | awk '{print $1}')
    OLD_SIZE=$(wc -c < "${OLD_BIN}")
    NEW_SIZE=$(wc -c < "${NEW_BIN}")

    echo "OLD sha256=${OLD_SHA} size=${OLD_SIZE}"
    echo "NEW sha256=${NEW_SHA} size=${NEW_SIZE}"

    if [ "${OLD_SHA}" = "${NEW_SHA}" ]; then
        log_info "OK: ${ARCH}: byte-identical (sha256 ${OLD_SHA})"
    else
        log_info "NOTE: ${ARCH}: sha256 differs -- analyzing the delta (RFC §5.1/S2 documented fallback)"
        if [ "${OLD_SIZE}" != "${NEW_SIZE}" ]; then
            log_fail "${ARCH}: sizes differ too (old=${OLD_SIZE} new=${NEW_SIZE}) -- NOT a benign build-id-only delta, treat as a possible real behavior change"
        else
            DIFF_COUNT=$(cmp -l "${OLD_BIN}" "${NEW_BIN}" 2>/dev/null | wc -l | tr -d ' ')
            FIRST_OFFSET=$(cmp -l "${OLD_BIN}" "${NEW_BIN}" 2>/dev/null | head -1 | awk '{print $1}')
            LAST_OFFSET=$(cmp -l "${OLD_BIN}" "${NEW_BIN}" 2>/dev/null | tail -1 | awk '{print $1}')
            SPAN=$((LAST_OFFSET - FIRST_OFFSET + 1))
            echo "byte-diff: ${DIFF_COUNT} differing byte(s), spanning offset ${FIRST_OFFSET}..${LAST_OFFSET} (span=${SPAN} bytes) out of ${OLD_SIZE} total"
            # A build-id-only delta is a small, contiguous span (Go's
            # buildid is a short hash embedded in one place) -- cap it at a
            # generous 512 bytes so a real, scattered behavioral diff still
            # fails loudly instead of being rationalized away.
            if [ "${SPAN}" -le 512 ] && [ "${DIFF_COUNT}" -le 512 ]; then
                log_info "OK: ${ARCH}: delta is a small contiguous span (${SPAN} bytes) -- consistent with Go's embedded build-id, not a functional change. DOCUMENTED DELTA: sha256 differs but binaries are equivalent modulo build-id."
            else
                log_fail "${ARCH}: delta spans ${SPAN} bytes across ${DIFF_COUNT} differing byte positions -- too large/scattered to be just a build-id; treat as a possible real behavior change (BLOCKER candidate)"
            fi
        fi
    fi

    docker rmi "${OLD_TAG}" "${NEW_TAG}" >/dev/null 2>&1 || true
done

harness_finish "tests/apk/legacy-identical.sh"
