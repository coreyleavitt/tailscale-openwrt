#!/bin/bash
# build-apk.sh -- build the OpenWrt 25 .apk (slice A2, RFC docs/rfc-apk-builds.md
# §3/§4.1). Sibling to build.sh (the ipk path), invoked separately -- it
# targets the additive `apk` Dockerfile stage and never touches the `ipk`
# stage, so it cannot affect build.sh's output.
#
# A5b widened this from one arch (A2 scope) to all four arches.json entries:
# the Dockerfile `apk` stage was already arch-generic (its GOARCH mapping
# already branches on OPENWRT_ARCH for all four cases -- see
# tailscale-package/Dockerfile), so the only generalization needed here is
# looping the existing single-arch build over every arches.json entry. Each
# arch's output stays namespaced under packages/<arch>/ as before.
#
# GOARCH/GOARM/GOMIPS/GOMIPS64/GO386 are explicitly looked up per-arch from
# arches.json below and passed to the Dockerfile as --build-arg (rather than
# left for the Dockerfile to guess from the OPENWRT_ARCH name) -- see
# build_one. This was fixed after two latent bugs: (1) the Dockerfile used
# to hardcode GOARM=7 for any `arm_cortex*` name, which is wrong for the
# bare, FPU-less `arm_cortex-a7` package arch (needs GOARM=5/softfloat) and
# would SIGILL on real hardware; (2) the Dockerfile derived GOARCH itself by
# a string-`case` on OPENWRT_ARCH with a `*) -> mips` default (RFC
# docs/rfc-apk-arch-coverage.md §5.1/S2), silently mis-building every arch
# outside aarch64*/arm_cortex*/mipsel* as 32-bit MIPS. All five build-tuple
# fields now come straight from arches.json; the Dockerfile hard-fails
# rather than guessing if GOARCH is missing or unrecognized.
#
# Usage:
#   build-apk.sh [version] [pkg_release] [arch]
#     arch given  -> build just that one arch (unchanged A2 behavior; this is
#                    how a CI per-arch matrix job or a test invokes it).
#     arch omitted -> build every arch listed in arches.json (repo root),
#                    in order, failing fast on the first error.
set -e

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
ARCHES_JSON="${REPO_ROOT}/arches.json"

VERSION="${1:-1.92.2}"
PKG_RELEASE="${2:-1}"
ARCH="${3:-}"

# Verify version exists
if ! curl -s -f -o /dev/null "https://github.com/tailscale/tailscale/releases/tag/v${VERSION}"; then
    echo "Error: Tailscale version v${VERSION} not found!"
    exit 1
fi

APK_VERSION="${VERSION}-r${PKG_RELEASE}"

# jq is needed to look up each arch's goarm/gomips from arches.json, whether
# building one arch (explicit $ARCH) or the whole matrix (loop below).
if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required" >&2
    exit 1
fi
if [ ! -f "${ARCHES_JSON}" ]; then
    echo "Error: ${ARCHES_JSON} not found" >&2
    exit 1
fi

build_one() {
    _arch="$1"

    # Look up this arch's full build tuple from arches.json and pass every
    # field through explicitly as --build-arg -- arches.json is the single
    # source of truth for the Go cross-compile flags; the Dockerfile no
    # longer re-derives any of them from the OPENWRT_ARCH string (RFC
    # docs/rfc-apk-arch-coverage.md §5.1/S2 -- it hard-fails instead of
    # guessing if goarch is missing/unrecognized). (Root cause of the
    # arm_cortex-a7 GOARM=7/hard-float SIGILL bug: the Dockerfile used to
    # hardcode GOARM=7 for any `arm_cortex*` name, ignoring arches.json's
    # goarm field entirely.)
    _goarch=$(jq -r --arg name "${_arch}" '.[] | select(.name == $name) | .goarch // ""' "${ARCHES_JSON}")
    _goarm=$(jq -r --arg name "${_arch}" '.[] | select(.name == $name) | .goarm // ""' "${ARCHES_JSON}")
    _gomips=$(jq -r --arg name "${_arch}" '.[] | select(.name == $name) | .gomips // ""' "${ARCHES_JSON}")
    _gomips64=$(jq -r --arg name "${_arch}" '.[] | select(.name == $name) | .gomips64 // ""' "${ARCHES_JSON}")
    _go386=$(jq -r --arg name "${_arch}" '.[] | select(.name == $name) | .go386 // ""' "${ARCHES_JSON}")

    echo "Building Tailscale .apk ${APK_VERSION} for ${_arch} (GOARCH=${_goarch:-none} GOARM=${_goarm:-none} GOMIPS=${_gomips:-none} GOMIPS64=${_gomips64:-none} GO386=${_go386:-none})..."
    mkdir -p "packages/${_arch}"

    docker build \
        --progress=plain \
        --target apk \
        --build-arg TAILSCALE_VERSION=${VERSION} \
        --build-arg PKG_RELEASE=${PKG_RELEASE} \
        --build-arg OPENWRT_ARCH=${_arch} \
        --build-arg GOARCH=${_goarch} \
        --build-arg GOARM=${_goarm} \
        --build-arg GOMIPS=${_gomips} \
        --build-arg GOMIPS64=${_gomips64} \
        --build-arg GO386=${_go386} \
        -t tailscale-apk-${_arch}:v${VERSION} \
        -f Dockerfile \
        . || { echo "Error: Failed to build ${_arch} .apk"; exit 1; }

    # Extract the .apk using docker cp (arch-namespaced path inside the image
    # -- RFC §3/§4.3: arch goes in the PATH, not the filename, to avoid a
    # same-filename collision across arches during CI artifact merge).
    CONTAINER_ID=$(docker create tailscale-apk-${_arch}:v${VERSION})
    docker cp "${CONTAINER_ID}:/out/${_arch}/tailscale-${APK_VERSION}.apk" "packages/${_arch}/" \
        || { echo "Error: Failed to extract ${_arch} .apk"; docker rm ${CONTAINER_ID} >/dev/null; exit 1; }
    docker rm ${CONTAINER_ID} >/dev/null

    # Validate package
    if [ ! -s "packages/${_arch}/tailscale-${APK_VERSION}.apk" ]; then
        echo "Error: ${_arch} .apk is empty or missing"
        exit 1
    fi

    echo "[OK] ${_arch} .apk built ($(du -h "packages/${_arch}/tailscale-${APK_VERSION}.apk" | cut -f1))"
}

if [ -n "${ARCH}" ]; then
    build_one "${ARCH}"
else
    # tier=="core" (RFC docs/rfc-apk-arch-coverage.md §5.8, slice S1c):
    # arches.json was widened to 35 rows in S1b (26 "extended" + 5
    # "infeasible", most with a blank/null build tuple -- pinning is
    # deferred to S7a). A bare `.[].name` here would iterate all 35 and
    # attempt to build the infeasible/unproven rows too. Gate to the same
    # tier=="core" set select-matrix.sh's non-PR branch and republish-feed
    # use, so this convenience "build everything" path stays consistent
    # with the migration-safety gate until S5 flips it.
    for _a in $(jq -r '.[] | select(.tier == "core") | .name' "${ARCHES_JSON}"); do
        build_one "${_a}"
    done
fi
