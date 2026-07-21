#!/bin/sh
# tests/apk/mkpkg.sh
#
# Slice A2 test: build the `apk` stage of tailscale-package/Dockerfile for
# one arch (aarch64_cortex-a53) -- the $PKGROOT build root (files/ payload +
# sibling scripts/) + `apk mkpkg` (RFC §3/§4.1) -- and assert:
#   - the .apk exists at the arch-namespaced output path
#   - `apk adbdump` reports name=tailscale, version=<ver>-r<rel>,
#     arch=aarch64_cortex-a53, and depends includes all four deps
#   - the on-device file list has NO CONTROL-shaped path and NO scripts/
#     path (RFC §4.1's "leak structurally impossible" claim, verified rather
#     than assumed)
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
# Uses the shared tests/apk/lib.sh harness (this slice establishes it).
#
# Usage: sh tests/apk/mkpkg.sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
PKG_DIR="${REPO_ROOT}/tailscale-package"

# shellcheck source=tests/apk/lib.sh
. "${SCRIPT_DIR}/lib.sh"

require_cmd docker

if [ ! -f "${PKG_DIR}/Dockerfile" ]; then
    echo "FAIL: ${PKG_DIR}/Dockerfile not found" >&2
    exit 1
fi

TEST_VERSION="${MKPKG_TEST_VERSION:-1.92.2}"
TEST_PKG_RELEASE="${MKPKG_TEST_PKG_RELEASE:-1}"
ARCH="aarch64_cortex-a53"
EXPECT_VERSION="${TEST_VERSION}-r${TEST_PKG_RELEASE}"
IMAGE_TAG="tailscale-apk-mkpkg-test:latest"
APK_PATH_IN_IMAGE="/out/${ARCH}/tailscale-${EXPECT_VERSION}.apk"

echo "Building apk stage (arch=${ARCH}, version=${EXPECT_VERSION})..."
if ! docker build \
    --target apk \
    --build-arg TAILSCALE_VERSION="${TEST_VERSION}" \
    --build-arg PKG_RELEASE="${TEST_PKG_RELEASE}" \
    --build-arg OPENWRT_ARCH="${ARCH}" \
    --build-arg SKIP_UPX=1 \
    -t "${IMAGE_TAG}" -f "${PKG_DIR}/Dockerfile" "${PKG_DIR}"; then
    log_fail "docker build --target apk failed"
    harness_finish "tests/apk/mkpkg.sh"
fi

# --- .apk exists at the arch-namespaced path -----------------------------
if docker_run "${IMAGE_TAG}" test -s "${APK_PATH_IN_IMAGE}"; then
    log_info "OK: .apk exists at ${APK_PATH_IN_IMAGE}"
else
    log_fail ".apk missing (or empty) at ${APK_PATH_IN_IMAGE}"
fi

# --- metadata via `apk adbdump` ------------------------------------------
DUMP=$(docker run --rm --entrypoint apk "${IMAGE_TAG}" adbdump "${APK_PATH_IN_IMAGE}" 2>&1) \
    || log_fail "apk adbdump failed (exit $?): ${DUMP}"
echo "--- apk adbdump output ---"
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
# postrm} -- post-install/pre-deinstall/post-deinstall. A2 already wired
# `--script "<hook>:$PKGROOT/scripts/<hook>"` into the mkpkg invocation; this
# slice is the assertion A2 left unwritten. Scoped to the `scripts:` section
# (sliced out of the dump below) rather than searched anywhere in ${DUMP}, so
# this would actually fail if a hook name were missing or misspelled in the
# --script flags, rather than passing on an incidental substring match
# elsewhere in the dump (e.g. inside script body comments).
SCRIPTS_BLOCK=$(printf '%s\n' "${DUMP}" | sed -n '/^scripts:/,/^# data block/p')

assert_contains "adbdump: scripts: section present" "${DUMP}" "scripts:"
assert_contains "adbdump: scripts block lists post-install" "${SCRIPTS_BLOCK}" "  post-install: |"
assert_contains "adbdump: scripts block lists pre-deinstall" "${SCRIPTS_BLOCK}" "  pre-deinstall: |"
assert_contains "adbdump: scripts block lists post-deinstall" "${SCRIPTS_BLOCK}" "  post-deinstall: |"

harness_finish "tests/apk/mkpkg.sh"
