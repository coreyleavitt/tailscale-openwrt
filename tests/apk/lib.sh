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

# harness_finish script_name -- print the pass/fail summary and exit
# accordingly. Call as the last line of every tests/apk/*.sh script.
harness_finish() {
    if [ "${FAIL}" -ne 0 ]; then
        echo "$1: FAILED" >&2
        exit 1
    fi
    echo "$1: OK"
}
