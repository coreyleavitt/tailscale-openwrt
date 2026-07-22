#!/bin/sh
# tests/apk/lib.sh
#
# Shared test-harness convention for tests/apk/*.sh (RFC §5: "self-contained
# tests/apk/<name>.sh scripts, runnable via `docker run` locally *and* as a
# CI step"). Established in slice A2 -- source, don't execute:
#
#   . "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh"
#
# POSIX sh only (no bashisms) so it runs under any /bin/sh. Deliberately
# minimal: a shared FAIL counter + a handful of log/assert helpers + a
# docker-run wrapper, not a framework. Each test script still owns its own
# control flow (what to build, what to assert) -- this only removes the
# boilerplate that was duplicated between host-apk.sh and rootfs.sh before A2.

# Shared pass/fail counter. A sourcing script should call harness_finish at
# the end (or check $FAIL itself) so any assertion failure exits non-zero.
FAIL=0

log_info() {
    echo "$1"
}

log_fail() {
    echo "FAIL: $1" >&2
    FAIL=1
}

# require_cmd name -- hard-exit immediately (not a soft FAIL) if a required
# tool isn't on PATH. Missing tooling is an environment problem, not a test
# assertion, so it doesn't go through the FAIL counter.
require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "FAIL: $1 is required but not found on PATH" >&2
        exit 1
    fi
}

# assert_eq description expected actual
assert_eq() {
    _desc="$1"; _expected="$2"; _actual="$3"
    if [ "${_expected}" = "${_actual}" ]; then
        log_info "OK: ${_desc} (${_actual})"
    else
        log_fail "${_desc}: expected '${_expected}', got '${_actual}'"
    fi
}

# assert_contains description haystack needle
assert_contains() {
    _desc="$1"; _haystack="$2"; _needle="$3"
    case "${_haystack}" in
        *"${_needle}"*) log_info "OK: ${_desc} (contains '${_needle}')" ;;
        *) log_fail "${_desc}: expected to contain '${_needle}', got: ${_haystack}" ;;
    esac
}

# assert_not_contains description haystack needle
assert_not_contains() {
    _desc="$1"; _haystack="$2"; _needle="$3"
    case "${_haystack}" in
        *"${_needle}"*) log_fail "${_desc}: expected NOT to contain '${_needle}', got: ${_haystack}" ;;
        *) log_info "OK: ${_desc} (does not contain '${_needle}')" ;;
    esac
}

# apk_arch_override_line native_line arch -- the ORIGINAL A4/A5b multi-arch
# `/etc/apk/arch` mechanism (RFC docs/rfc-apk-builds.md correction 1): append
# `arch` as an additional acceptable line after whatever the container
# already reports, UNCONDITIONALLY (no check that `arch` matches natively).
# Kept, unchanged, for install.sh's DEFAULT (non-native-only) path -- the
# ipk_arches-scoped legacy install coverage for aarch64_cortex-a53/
# arm_cortex-a7 genuinely needs this (RFC §5.6/S7a's D2: "keep existing
# multi-arch install coverage that needs the override in a clearly separate,
# named path"). Pure string function, no docker -- factored out purely so
# tests/apk/install-native-verify.sh can assert its behavior hermetically.
apk_arch_override_line() {
    printf '%s\n%s' "$1" "$2"
}

# native_arch_matches native_line arch -- S7a/D2's native-only assertion:
# true (exit 0) iff the container's OWN reported arch (the FIRST line of
# native_line -- a stock device's /etc/apk/arch reports its own arch on line
# one; any later line is a fallback, not what the device itself IS) already
# equals `arch`, verbatim, with NO mutation performed. This is what
# INSTALL_NATIVE_ONLY=1 uses in tests/apk/install.sh instead of
# apk_arch_override_line -- a family whose verify_families representative
# genuinely IS the native arch (every S7a-pinned family, by construction --
# see scripts/arches.sh --with-ci) passes this without any override; a
# mismatch here is exactly the class of bug D2 removes the override to catch
# (e.g. arm_cortex-a7 against armsr/armv7's native arm_cortex-a15_neon-vfpv4).
native_arch_matches() {
    _native_first_line=$(printf '%s\n' "$1" | head -n1)
    [ "${_native_first_line}" = "$2" ]
}

# docker_run image [args...] -- thin wrapper kept for a single, consistent
# call style across tests; captures nothing itself (callers decide whether
# to capture output), just runs `docker run --rm`.
docker_run() {
    _image="$1"
    shift
    docker run --rm "${_image}" "$@"
}

# register_standard_qemu_binfmt -- register the stock qemu-user binfmt_misc
# emulators for all arches multiarch/qemu-user-static ships (aarch64, armv7,
# mips64/mips64el, etc). `--reset` clears any prior registration first, so
# this is idempotent and safe to call at the start of a fresh run. Requires
# --privileged docker. This is the local-test equivalent of the CI
# `docker/setup-qemu-action` step (§6 slice A5a) -- same underlying
# multiarch/qemu-user-static mechanism, invoked directly since there is no
# GitHub Actions runner locally.
register_standard_qemu_binfmt() {
    docker run --rm --privileged multiarch/qemu-user-static --reset -p yes >/dev/null
}

# register_openwrt_mips_binfmt -- register custom qemu-mips-owrt/
# qemu-mipsel-owrt binfmt_misc entries for OpenWrt's 32-bit mips/mipsel
# musl-softfloat binaries (RFC docs/rfc-apk-builds.md §6 slice A5a, root-
# caused in A0). Neither `docker/setup-qemu-action`/`tonistiigi/binfmt` (omit
# 32-bit mips/mipsel entirely) nor multiarch/qemu-user-static's own stock
# mips/mipsel entries (reject them) can exec these binaries: their ELF
# e_ident[EI_ABIVERSION] byte is 1, but the stock magic/mask requires that
# byte to be 0, so `docker run` fails "exec format error" even though qemu
# itself emulates the ISA fine. This registers entries identical to the
# stock qemu-mips/qemu-mipsel ones except that one byte is wildcarded in the
# mask. Requires --privileged docker; safe to call repeatedly (removes any
# prior owrt entries first).
#
# binfmt_misc magic/mask containing embedded 0x00 bytes MUST be written as
# literal \xHH text -- the kernel's own register parser decodes the escapes
# internally; pre-decoding to raw bytes before writing (e.g. via `xxd -r -p`)
# breaks because the kernel's field-splitting is NUL-unsafe and truncates at
# the first embedded 0x00 byte in the magic/mask.
register_openwrt_mips_binfmt() {
    docker run --rm --privileged --entrypoint sh multiarch/qemu-user-static -c '
        set -e
        mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
        for n in qemu-mips-owrt qemu-mipsel-owrt; do
            if [ -e "/proc/sys/fs/binfmt_misc/$n" ]; then
                echo -1 > "/proc/sys/fs/binfmt_misc/$n"
            fi
        done
        printf "%s" ":qemu-mips-owrt:M::\x7f\x45\x4c\x46\x01\x02\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x08:\xff\xff\xff\xff\xff\xff\xff\x00\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff:/usr/bin/qemu-mips-static:F" > /proc/sys/fs/binfmt_misc/register
        printf "%s" ":qemu-mipsel-owrt:M::\x7f\x45\x4c\x46\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x08\x00:\xff\xff\xff\xff\xff\xff\xff\x00\x00\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/qemu-mipsel-static:F" > /proc/sys/fs/binfmt_misc/register
    '
}

# register_loongarch64_binfmt -- S7a M3 spike finding: multiarch/qemu-user-
# static (register_standard_qemu_binfmt above) does NOT ship a loong64
# emulator at all -- a loongarch64 container exec's "exec format error"
# under it, regardless of qemu's own ISA support. The runner's ACTUAL CI
# qemu setup (`docker/setup-qemu-action@v3`) is backed by tonistiigi/binfmt
# instead, which DOES register `qemu-loongarch64` (empirically confirmed:
# a pinned OpenWrt 25.12 loongarch64/generic rootfs execs and reports its
# real native /etc/apk/arch, loongarch64_generic, under it) -- so CI itself
# needs no change here. This is purely a LOCAL-dev-parity supplement (mirrors
# register_openwrt_mips_binfmt's "layer one more specific registration on
# top" shape) so a bare local `sh tests/apk/qemu.sh` (all verify_families,
# no CI runner) can also exec the loong64 leg. Requires --privileged docker;
# safe to call repeatedly.
register_loongarch64_binfmt() {
    docker run --rm --privileged tonistiigi/binfmt --install linux/loong64 >/dev/null
}

# extract_apk_tools_binary dest_dir pkg_dir -- build the `apk-tools` stage
# of <pkg_dir>/Dockerfile (the pinned OpenWrt 25.12.0 host apk-tools 3.0.2
# binary, established A1) and copy the resulting `apk` binary to
# <dest_dir>/apk (chmod +x). Reused by slice C3's feed-guard.sh callers --
# both tests/apk/feed-publish.sh and the `publish-feed` workflow job need a
# real `apk` on PATH (adbdump/version -t/mkndx), and this is the single
# place that knows how to get one, mirroring host-apk.sh's own build step
# rather than re-deriving/duplicating it. Idempotent (docker build layer
# cache makes repeat calls cheap); does NOT modify PATH itself -- callers
# add <dest_dir> to PATH themselves so this stays a pure "get me the binary"
# helper, not a shell-environment mutator. Takes pkg_dir explicitly (rather
# than deriving it from $0) since this runs as a sourced function -- $0
# would be whichever script sourced lib.sh, not lib.sh's own location.
extract_apk_tools_binary() {
    _dest_dir="$1"
    _pkg_dir="$2"
    _image_tag="tailscale-apk-tools-pinned:latest"

    docker build --target apk-tools -t "${_image_tag}" -f "${_pkg_dir}/Dockerfile" "${_pkg_dir}" >&2

    mkdir -p "${_dest_dir}"
    _cid=$(docker create "${_image_tag}")
    docker cp "${_cid}:/usr/local/bin/apk" "${_dest_dir}/apk"
    docker rm -f "${_cid}" >/dev/null 2>&1 || true
    chmod +x "${_dest_dir}/apk"
}

# build_apk_host pkg_dir arch goarch goarm gomips gomips64 go386 version \
#                pkg_release out_apk build_image_tag [skip_upx]
#
# Slice S4 (RFC docs/rfc-apk-arch-coverage.md §5.1/§5.3): the Dockerfile
# `apk` stage was DELETED this slice -- `docker build --target apk` no
# longer exists. This is the ONE replacement every test that used to build
# that stage now calls: compile the family binary
# (`docker build --target build`, this repo's single compile path) then
# package host-side via scripts/package-apk.sh (no second docker build),
# exactly what the `build-apk` CI job's in-job packaging loop does. Kept in
# lib.sh (not re-derived per test file) so there is exactly one "how do I
# get an .apk out of this repo" implementation for tests to share -- the
# same "retire the code it replaces" principle §5.1 applies to
# package-apk.sh itself.
#
# Tags the compiled `build`-stage image as <build_image_tag> (a plain
# argument, not auto-generated) so callers that ALSO need a live container
# with `apk` on PATH afterward (e.g. building an offline stub-dep repo via
# `docker exec ... apk mkpkg`, the A4/A5b/C2 trick) can reuse it directly --
# the `build` stage still COPYs the pinned host apk-tools binary to
# /usr/local/bin/apk internally, unchanged by this slice.
#
# SOURCE_DATE_EPOCH is read from the compiled image's own
# /build/tailscale.tar.gz mtime (the same source the old Dockerfile `apk`
# stage used internally), so the produced .apk stays exactly as
# deterministic as before this migration.
#
# Writes the finished .apk to <out_apk> (parent dir created by
# package-apk.sh). Prints docker/package-apk.sh output to stderr; returns
# non-zero on any failure (does not itself log_fail -- callers decide how
# to report, mirroring extract_apk_tools_binary's convention).
build_apk_host() {
    _pkg_dir="$1"; _arch="$2"
    _goarch="$3"; _goarm="$4"; _gomips="$5"; _gomips64="$6"; _go386="$7"
    _version="$8"; _pkg_release="$9"
    shift 9
    _out_apk="$1"; _build_image_tag="$2"; _skip_upx="${3:-1}"

    _repo_root=$(CDPATH= cd -- "${_pkg_dir}/.." && pwd)
    _full_version="${_version}-r${_pkg_release}"

    if ! docker build \
        --target build \
        --build-arg TAILSCALE_VERSION="${_version}" \
        --build-arg PKG_RELEASE="${_pkg_release}" \
        --build-arg OPENWRT_ARCH="${_arch}" \
        --build-arg GOARCH="${_goarch}" \
        --build-arg GOARM="${_goarm}" \
        --build-arg GOMIPS="${_gomips}" \
        --build-arg GOMIPS64="${_gomips64}" \
        --build-arg GO386="${_go386}" \
        --build-arg SKIP_UPX="${_skip_upx}" \
        -t "${_build_image_tag}" -f "${_pkg_dir}/Dockerfile" "${_pkg_dir}" >&2; then
        echo "build_apk_host: docker build --target build failed for ${_arch}" >&2
        return 1
    fi

    _bin_dir=$(mktemp -d)
    _bcid=$(docker create "${_build_image_tag}")
    docker cp "${_bcid}:/build/tailscaled" "${_bin_dir}/tailscaled"
    _sde=$(docker run --rm --entrypoint stat "${_build_image_tag}" -c %Y /build/tailscale.tar.gz)
    docker rm -f "${_bcid}" >/dev/null 2>&1 || true

    _apk_tools_dir=$(mktemp -d)
    extract_apk_tools_binary "${_apk_tools_dir}" "${_pkg_dir}"

    _rc=0
    SOURCE_DATE_EPOCH="${_sde}" sh "${_repo_root}/scripts/package-apk.sh" \
        --binary "${_bin_dir}/tailscaled" \
        --arch "${_arch}" \
        --version "${_full_version}" \
        --payload "${_pkg_dir}/src" \
        --apk-bin "${_apk_tools_dir}/apk" \
        --out "${_out_apk}" >&2 || _rc=$?

    rm -rf "${_bin_dir}" "${_apk_tools_dir}"
    return "${_rc}"
}

# harness_finish script_name -- print the pass/fail summary and exit
# accordingly. Call as the last line of every tests/apk/*.sh script.
harness_finish() {
    if [ "${FAIL}" -ne 0 ]; then
        echo "$1: FAILED" >&2
        exit 1
    fi
    echo "$1: OK"
}
