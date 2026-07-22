#!/bin/sh
# tests/apk/mkpkg.sh
#
# Slice A2 test (RFC docs/rfc-apk-builds.md), REWRITTEN for slice S3 (RFC
# docs/rfc-apk-arch-coverage.md §5.1/S3): builds the .apk via the new
# host-side `scripts/package-apk.sh` -- NO `docker build --target apk` --
# and asserts the same properties A2/A3b established:
#   - the .apk exists at the output path
#   - `apk adbdump` reports name=tailscale, version=<ver>-r<rel>,
#     arch=aarch64_cortex-a53, and depends includes all four deps
#   - the on-device file list has NO CONTROL-shaped path and NO scripts/
#     path (RFC §4.1's "leak structurally impossible" claim)
#   - lib/apk/packages/tailscale.conffiles IS shipped as a real payload file
#     (Q1, see below)
#   - the scripts: block lists exactly the three apk lifecycle hooks
#   - the sysupgrade keep.d/tailscale file is present with the right size
#
# Q1 finding (empirical, corrects an assumption in the RFC/A2 brief): the
# brief's hypothesis was that `lib/apk/packages/<name>.conffiles` should be
# EXCLUDED from the shipped payload, like ipk's CONTROL/conffiles (build
# metadata only, never installed). That is wrong for apk. `apk mkpkg --help`
# has no `--info conffiles:...` key at all (its recognized --info keys are
# name/version/description/arch/license/maintainer/depends/provides/
# replaces/install-if/origin/triggers -- verified via `strings` on the
# apk-tools 3.0.2 binary); conffiles is not part of the ADB info schema.
# Cross-checked against upstream `include/package-pack.mk` (git.openwrt.org,
# the RFC's own cited source): it does
#   mv -f $(ADIR)/conffiles $(IDIR)/lib/apk/packages/$(name).conffiles
# i.e. it deliberately MOVES the conffiles list INTO the `--files` payload
# dir (their IDIR, our files/). So a real on-device
# `lib/apk/packages/tailscale.conffiles` file, installed as a normal file,
# IS the correct, intentional apk v3 mechanism (the client-side conffile
# protection is payload-driven, not an ADB metadata field) -- this test
# asserts it IS present with the right content, not absent.
#
# Slice S3 addition -- host-side rebuild + byte-identical (adbdump-level)
# check: this test ALSO builds the same arch/version through the (still
# extant, not-yet-deleted -- that's S4) Dockerfile `apk` stage and diffs the
# two `apk adbdump` outputs, asserting they agree on everything except a
# short, DOCUMENTED nondeterminism allowlist:
#   - `hashes:`/`installed-size:` -- checksums/aggregates computed OVER the
#     varying fields below, so they necessarily differ whenever those do.
#   - `user:`/`group:` -- apk mkpkg records the FILESYSTEM owner of each
#     staged file at build time (empirically: NOT normalized to nobody:
#     nobody as an earlier note in this repo assumed); the Docker build runs
#     as container root (root:root), the host-side build runs as whatever
#     user invokes package-apk.sh -- an environment artifact, not a payload
#     difference.
#   - `xattrs: ug.archive_bit=...` -- an overlayfs-only extended attribute
#     Docker's storage driver stamps on files written inside a container
#     layer; the host-side build (a plain tmpfs/local filesystem) never has
#     it. Also an environment artifact.
#   - `mtime:` -- NOT allowlisted: both builds are pinned to the SAME
#     SOURCE_DATE_EPOCH below (read from the Docker build stage's own
#     tailscale.tar.gz mtime, the exact value the Dockerfile apk stage
#     computes internally), so this test proves mtimes match exactly rather
#     than papering over a real determinism gap.
# Every other line (paths, sizes, hashes-of-content via the per-file `hash:`
# under the SAME mtime, info: fields, scripts: bodies) must match verbatim.
#
# Uses the shared tests/apk/lib.sh harness (established slice A2);
# extract_apk_tools_binary (added for slice C3) supplies the host apk-tools
# 3.0.2 binary package-apk.sh needs for --apk-bin.
#
# Usage: sh tests/apk/mkpkg.sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
PKG_DIR="${REPO_ROOT}/tailscale-package"
PACKAGE_APK="${REPO_ROOT}/scripts/package-apk.sh"

# shellcheck source=tests/apk/lib.sh
. "${SCRIPT_DIR}/lib.sh"

require_cmd docker

if [ ! -f "${PKG_DIR}/Dockerfile" ]; then
    echo "FAIL: ${PKG_DIR}/Dockerfile not found" >&2
    exit 1
fi
if [ ! -f "${PACKAGE_APK}" ]; then
    echo "FAIL: ${PACKAGE_APK} not found" >&2
    exit 1
fi

TEST_VERSION="${MKPKG_TEST_VERSION:-1.92.2}"
TEST_PKG_RELEASE="${MKPKG_TEST_PKG_RELEASE:-1}"
ARCH="aarch64_cortex-a53"
EXPECT_VERSION="${TEST_VERSION}-r${TEST_PKG_RELEASE}"

WORKDIR=$(mktemp -d)
trap 'rm -rf "${WORKDIR}"' EXIT

# --- 1. compile the family binary (docker build --target build) ---------
# RFC docs/rfc-apk-arch-coverage.md §5.1/S2: the Dockerfile's `build` stage
# no longer derives GOARCH from OPENWRT_ARCH's name, so it must be passed
# explicitly -- aarch64_cortex-a53 is arches.json's arm64 core arch.
BUILD_IMAGE_TAG="tailscale-mkpkg-build-test:latest"
echo "Compiling family binary (arch=${ARCH}, version=${EXPECT_VERSION})..."
if ! docker build \
    --target build \
    --build-arg TAILSCALE_VERSION="${TEST_VERSION}" \
    --build-arg PKG_RELEASE="${TEST_PKG_RELEASE}" \
    --build-arg OPENWRT_ARCH="${ARCH}" \
    --build-arg GOARCH=arm64 \
    --build-arg SKIP_UPX=1 \
    -t "${BUILD_IMAGE_TAG}" -f "${PKG_DIR}/Dockerfile" "${PKG_DIR}"; then
    log_fail "docker build --target build failed"
    harness_finish "tests/apk/mkpkg.sh"
fi

mkdir -p "${WORKDIR}/bin"
BCID=$(docker create "${BUILD_IMAGE_TAG}")
docker cp "${BCID}:/build/tailscaled" "${WORKDIR}/bin/tailscaled"
# Same SOURCE_DATE_EPOCH source the Dockerfile apk stage itself uses
# (tailscale.tar.gz's mtime -- GitHub sets archive mtimes to the tagged
# commit time), read out of the same image so both builds below are pinned
# to the identical value -- this is what lets the byte-identical check
# assert on `mtime:` too, not just structure.
SOURCE_DATE_EPOCH=$(docker run --rm --entrypoint stat "${BUILD_IMAGE_TAG}" -c %Y /build/tailscale.tar.gz)
docker rm -f "${BCID}" >/dev/null
export SOURCE_DATE_EPOCH
echo "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH} (from ${BUILD_IMAGE_TAG}'s /build/tailscale.tar.gz mtime)"

# --- 2. host apk-tools (mkpkg/mkndx), pinned OpenWrt 25.12.0 3.0.2 -------
extract_apk_tools_binary "${WORKDIR}/apk-tools" "${PKG_DIR}"

# --- 3. build the .apk host-side, via scripts/package-apk.sh (NO docker) -
HOST_OUT="${WORKDIR}/host-out/tailscale-${EXPECT_VERSION}.apk"
echo "Building .apk host-side via package-apk.sh..."
if ! sh "${PACKAGE_APK}" \
    --binary "${WORKDIR}/bin/tailscaled" \
    --arch "${ARCH}" \
    --version "${EXPECT_VERSION}" \
    --payload "${PKG_DIR}/src" \
    --apk-bin "${WORKDIR}/apk-tools/apk" \
    --out "${HOST_OUT}"; then
    log_fail "scripts/package-apk.sh failed"
    harness_finish "tests/apk/mkpkg.sh"
fi

# --- .apk exists ----------------------------------------------------------
if [ -s "${HOST_OUT}" ]; then
    log_info "OK: .apk exists at ${HOST_OUT}"
else
    log_fail ".apk missing (or empty) at ${HOST_OUT}"
fi

# --- metadata via `apk adbdump` (host apk-tools, no docker) --------------
DUMP=$("${WORKDIR}/apk-tools/apk" adbdump "${HOST_OUT}" 2>&1) \
    || log_fail "apk adbdump failed (exit $?): ${DUMP}"
echo "--- apk adbdump output (host-built) ---"
echo "${DUMP}"
echo "--- end adbdump output ---"

assert_contains "adbdump: name" "${DUMP}" "tailscale"
assert_contains "adbdump: version" "${DUMP}" "${EXPECT_VERSION}"
assert_contains "adbdump: arch" "${DUMP}" "${ARCH}"
assert_contains "adbdump: depends kmod-tun" "${DUMP}" "kmod-tun"
assert_contains "adbdump: depends ca-bundle" "${DUMP}" "ca-bundle"
assert_contains "adbdump: depends ip-full" "${DUMP}" "ip-full"
assert_contains "adbdump: depends conntrack" "${DUMP}" "conntrack"

# --- on-device file list: no CONTROL/, no scripts/ (Q2) -------------------
assert_not_contains "adbdump: no CONTROL path" "${DUMP}" "CONTROL"
assert_not_contains "adbdump: no scripts/ path" "${DUMP}" "scripts/"

# --- conffiles IS shipped as a real payload file (Q1, see header note) ---
# adbdump nests path components (a "lib/apk/packages" dir entry containing a
# "tailscale.conffiles" files: entry), so the two are asserted separately
# rather than as one concatenated literal string.
assert_contains "adbdump: lib/apk/packages dir present" "${DUMP}" "name: lib/apk/packages"
assert_contains "adbdump: tailscale.conffiles file present" "${DUMP}" "name: tailscale.conffiles"
assert_contains "adbdump: tailscale.conffiles size matches '/etc/config/tailscale\\n' (22 bytes)" "${DUMP}" "size: 22"

# --- maintainer-script mapping (A3b): scripts: block lists exactly the three
# apk lifecycle hooks the RFC (§4.1) maps from src/tailscale.{postinst,prerm,
# postrm} -- post-install/pre-deinstall/post-deinstall. Scoped to the
# `scripts:` section (sliced out of the dump below) rather than searched
# anywhere in ${DUMP}, so this would actually fail if a hook name were
# missing or misspelled in the --script flags, rather than passing on an
# incidental substring match elsewhere in the dump.
SCRIPTS_BLOCK=$(printf '%s\n' "${DUMP}" | sed -n '/^scripts:/,/^# data block/p')

assert_contains "adbdump: scripts: section present" "${DUMP}" "scripts:"
assert_contains "adbdump: scripts block lists post-install" "${SCRIPTS_BLOCK}" "  post-install: |"
assert_contains "adbdump: scripts block lists pre-deinstall" "${SCRIPTS_BLOCK}" "  pre-deinstall: |"
assert_contains "adbdump: scripts block lists post-deinstall" "${SCRIPTS_BLOCK}" "  post-deinstall: |"

# --- sysupgrade keep-list: /etc/tailscale/ survives a firmware upgrade ---
# adbdump nests path components (a "lib/upgrade/keep.d" dir entry containing
# a "tailscale" file entry), and -- unlike the conffiles check above -- the
# bare substrings "name: tailscale" and "size: 16" are NOT unique enough to
# assert directly against the whole dump: "name: tailscale" already matches
# the package's own `info: name: tailscale` field (and the pre-existing
# usr/bin/tailscale wrapper file entry) regardless of this fix, so a naive
# assert_contains against ${DUMP} would pass even with no keep.d file at all.
# Scope to the lib/upgrade/keep.d dir entry's own nested block first (same
# technique as SCRIPTS_BLOCK above), then assert within that scoped block.
KEEPD_BLOCK=$(printf '%s\n' "${DUMP}" | awk '
    /^  - name: lib\/upgrade\/keep\.d$/ { grab=1; print; next }
    grab && /^  - name:/ { exit }
    grab { print }
')

assert_contains "adbdump: lib/upgrade/keep.d dir present" "${DUMP}" "name: lib/upgrade/keep.d"
assert_contains "adbdump: keep.d block contains tailscale file" "${KEEPD_BLOCK}" "name: tailscale"
assert_contains "adbdump: keep.d/tailscale size matches '/etc/tailscale/\\n' (16 bytes)" "${KEEPD_BLOCK}" "size: 16"

# --- 4. byte-identical (adbdump-level) check against the Dockerfile apk --
# stage, same inputs (RFC §5.1/S3 "Retire the code it replaces" -- until S4
# deletes the Dockerfile apk stage, this proves the two implementations
# agree). See the header note for the exact, documented nondeterminism
# allowlist (hashes:/installed-size:/user:/group:/xattrs:).
echo "Building the same .apk via the (still extant) Dockerfile apk stage, for comparison..."
DOCKER_IMAGE_TAG="tailscale-mkpkg-docker-compare:latest"
if ! docker build \
    --target apk \
    --build-arg TAILSCALE_VERSION="${TEST_VERSION}" \
    --build-arg PKG_RELEASE="${TEST_PKG_RELEASE}" \
    --build-arg OPENWRT_ARCH="${ARCH}" \
    --build-arg GOARCH=arm64 \
    --build-arg SKIP_UPX=1 \
    -t "${DOCKER_IMAGE_TAG}" -f "${PKG_DIR}/Dockerfile" "${PKG_DIR}"; then
    log_fail "docker build --target apk (comparison build) failed"
    harness_finish "tests/apk/mkpkg.sh"
fi

DOCKER_APK_PATH_IN_IMAGE="/out/${ARCH}/tailscale-${EXPECT_VERSION}.apk"
DOCKER_DUMP=$(docker run --rm --entrypoint apk "${DOCKER_IMAGE_TAG}" adbdump "${DOCKER_APK_PATH_IN_IMAGE}" 2>&1) \
    || log_fail "apk adbdump (docker-built) failed (exit $?): ${DOCKER_DUMP}"

NORMALIZE_PATTERN='user:|group:|hashes:|xattrs:|ug\.archive_bit|installed-size:|^# ADB block'
HOST_NORM="${WORKDIR}/host-norm.txt"
DOCKER_NORM="${WORKDIR}/docker-norm.txt"
printf '%s\n' "${DUMP}" | grep -vE "${NORMALIZE_PATTERN}" > "${HOST_NORM}"
printf '%s\n' "${DOCKER_DUMP}" | grep -vE "${NORMALIZE_PATTERN}" > "${DOCKER_NORM}"

if DIFF_OUT=$(diff "${DOCKER_NORM}" "${HOST_NORM}" 2>&1); then
    log_info "OK: host-built .apk adbdump-equivalent to Dockerfile-apk-stage-built .apk (modulo user/group/xattrs/hashes/installed-size)"
else
    log_fail "host-built vs Dockerfile-apk-stage-built .apk differ beyond the documented nondeterminism allowlist:
${DIFF_OUT}"
fi

docker rmi "${BUILD_IMAGE_TAG}" "${DOCKER_IMAGE_TAG}" >/dev/null 2>&1 || true

harness_finish "tests/apk/mkpkg.sh"
