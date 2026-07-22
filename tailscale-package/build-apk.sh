#!/bin/bash
# build-apk.sh -- build the OpenWrt 25 .apk (slice A2, RFC docs/rfc-apk-builds.md
# §3/§4.1). Sibling to build.sh (the ipk path), invoked separately -- it
# never touches the `ipk` stage, so it cannot affect build.sh's output.
#
# A5b widened this from one arch (A2 scope) to all four arches.json entries:
# looping the existing single-arch build over every arches.json entry, each
# arch's output namespaced under packages/<arch>/.
#
# RFC docs/rfc-apk-arch-coverage.md §5.1/S4: the Dockerfile `apk` stage this
# script used to build via `--target apk` was DELETED this slice -- apk
# packaging is host-side now (scripts/package-apk.sh), never a second Docker
# build. build_one below compiles via `--target build` (still driven
# explicitly by arches.json's per-arch goarch/goarm/gomips/gomips64/go386
# fields, per S2 -- the Dockerfile hard-fails rather than guessing if
# GOARCH is missing/unrecognized) and packages via package-apk.sh, mirroring
# the `build-apk` CI job's own per-arch compile+package path.
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
PACKAGE_APK="${REPO_ROOT}/scripts/package-apk.sh"

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
if [ ! -f "${PACKAGE_APK}" ]; then
    echo "Error: ${PACKAGE_APK} not found" >&2
    exit 1
fi

# extract_apk_tools_binary (tests/apk/lib.sh, POSIX sh -- sourced here since
# this script needs the exact same pinned host apk-tools 3.0.2 binary
# package-apk.sh requires for --apk-bin, and this is the single existing
# implementation of "how do I get one").
# shellcheck source=tests/apk/lib.sh
. "${REPO_ROOT}/tests/apk/lib.sh"

APK_TOOLS_DIR=$(mktemp -d)
cleanup() { rm -rf "${APK_TOOLS_DIR}"; }
trap cleanup EXIT
extract_apk_tools_binary "${APK_TOOLS_DIR}" "${SCRIPT_DIR}"

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

    # Compile: `--target build` (the `apk` stage no longer exists).
    docker build \
        --progress=plain \
        --target build \
        --build-arg TAILSCALE_VERSION=${VERSION} \
        --build-arg PKG_RELEASE=${PKG_RELEASE} \
        --build-arg OPENWRT_ARCH=${_arch} \
        --build-arg GOARCH=${_goarch} \
        --build-arg GOARM=${_goarm} \
        --build-arg GOMIPS=${_gomips} \
        --build-arg GOMIPS64=${_gomips64} \
        --build-arg GO386=${_go386} \
        -t tailscale-build-${_arch}:v${VERSION} \
        -f Dockerfile \
        . || { echo "Error: Failed to build ${_arch} binary"; exit 1; }

    CONTAINER_ID=$(docker create tailscale-build-${_arch}:v${VERSION})
    BIN_DIR=$(mktemp -d)
    docker cp "${CONTAINER_ID}:/build/tailscaled" "${BIN_DIR}/tailscaled" \
        || { echo "Error: Failed to extract ${_arch} binary"; docker rm "${CONTAINER_ID}" >/dev/null; exit 1; }
    SDE=$(docker run --rm --entrypoint stat tailscale-build-${_arch}:v${VERSION} -c %Y /build/tailscale.tar.gz)
    docker rm "${CONTAINER_ID}" >/dev/null

    # Package: host-side, no docker (RFC §5.1/S3/S4).
    SOURCE_DATE_EPOCH="${SDE}" sh "${PACKAGE_APK}" \
        --binary "${BIN_DIR}/tailscaled" \
        --arch "${_arch}" \
        --version "${APK_VERSION}" \
        --payload "${SCRIPT_DIR}/src" \
        --apk-bin "${APK_TOOLS_DIR}/apk" \
        --out "packages/${_arch}/tailscale-${APK_VERSION}.apk" \
        || { echo "Error: Failed to package ${_arch} .apk"; rm -rf "${BIN_DIR}"; exit 1; }
    rm -rf "${BIN_DIR}"

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
    #
    # M4 (code-review finding): "which arches are tier==core" is
    # scripts/families.sh --tier-arches's own accessor -- the single
    # authored place that predicate lives -- not a second `select(.tier ==
    # "core")` jq literal here.
    for _a in $(sh "${REPO_ROOT}/scripts/families.sh" --tier-arches core "${ARCHES_JSON}"); do
        build_one "${_a}"
    done
fi
