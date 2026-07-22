#!/bin/sh
# tests/apk/install-native-verify.sh
#
# Slice S7a/D2 test (RFC docs/rfc-apk-arch-coverage.md §5.6): the qemu-verify
# native-arch install path must exercise the device's REAL, un-mutated
# `/etc/apk/arch` -- not an appended test arch. tests/apk/install.sh's
# multi-arch override (`printf '%s\n%s\n' "${NATIVE_ARCH_LINE}" "${ARCH}" >
# /etc/apk/arch`, added in A4/A5b) is exactly the mechanism that HID the
# original arm_cortex-a7-vs-armsr/armv7 mismatch: it makes a foreign arch tag
# acceptable by APPENDING it, regardless of whether the container's rootfs
# genuinely reports that arch natively.
#
# This is tested HERMETICALLY (no docker/qemu) by pulling the decision logic
# out into two pure tests/apk/lib.sh functions and asserting their behavior
# directly against fixture strings:
#   - apk_arch_override_line(native_line, arch): the EXISTING (unchanged)
#     override behavior -- appends `arch` as an additional acceptable line,
#     regardless of whether it matches nativement. Still used by the
#     non-native-only default path (kept for the ipk_arches-scoped, already-
#     override-dependent coverage of aarch64_cortex-a53/arm_cortex-a7 -- RFC
#     §5.6's D2 note: "keep existing multi-arch install coverage that
#     genuinely needs the override in a clearly separate, named path").
#   - native_arch_matches(native_line, arch): the NEW native-only assertion --
#     true iff the container's OWN first line already equals `arch`, with NO
#     mutation of /etc/apk/arch at all. This is what INSTALL_NATIVE_ONLY=1
#     uses in tests/apk/install.sh's install_verify_one.
#
# Usage: sh tests/apk/install-native-verify.sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# shellcheck source=tests/apk/lib.sh
. "${SCRIPT_DIR}/lib.sh"

echo "=== apk_arch_override_line: appends the build arch regardless of match ==="

assert_eq "override line: native + a genuinely different arch appended" \
    "$(printf 'arm_cortex-a15_neon-vfpv4\narm_cortex-a7')" \
    "$(apk_arch_override_line 'arm_cortex-a15_neon-vfpv4' 'arm_cortex-a7')"

assert_eq "override line: native + a matching arch (still appended, idempotent-ish)" \
    "$(printf 'mips_24kc\nmips_24kc')" \
    "$(apk_arch_override_line 'mips_24kc' 'mips_24kc')"

echo

echo "=== native_arch_matches: true iff the container's OWN first line already equals arch ==="

if native_arch_matches "mips_24kc" "mips_24kc"; then
    log_info "OK: native_arch_matches('mips_24kc', 'mips_24kc') is true (genuine native match, e.g. M32BE)"
else
    log_fail "native_arch_matches('mips_24kc', 'mips_24kc') should be true"
fi

if native_arch_matches "aarch64_generic" "aarch64_generic"; then
    log_info "OK: native_arch_matches('aarch64_generic', 'aarch64_generic') is true (A64's true S7a representative)"
else
    log_fail "native_arch_matches('aarch64_generic', 'aarch64_generic') should be true"
fi

# THE regression case: arm_cortex-a7 (softfloat/ASOFT) against the
# armsr/armv7 rootfs, whose OWN native line is arm_cortex-a15_neon-vfpv4
# (hardfloat/A7HF) -- the exact mismatch the override used to paper over.
if native_arch_matches "arm_cortex-a15_neon-vfpv4" "arm_cortex-a7"; then
    log_fail "native_arch_matches('arm_cortex-a15_neon-vfpv4', 'arm_cortex-a7') should be FALSE (the D2 regression case)"
else
    log_info "OK: native_arch_matches('arm_cortex-a15_neon-vfpv4', 'arm_cortex-a7') is false -- the exact mismatch D2 removes the override for"
fi

echo

echo "=== native_arch_matches: only the FIRST line of a multi-line /etc/apk/arch counts ==="

if native_arch_matches "$(printf 'aarch64_generic\naarch64\nnoarch')" "aarch64_generic"; then
    log_info "OK: multi-line native content matches on its first line"
else
    log_fail "native_arch_matches should match against the first line of a multi-line native_line"
fi

if native_arch_matches "$(printf 'aarch64_generic\naarch64\nnoarch')" "aarch64"; then
    log_fail "native_arch_matches should NOT match a fallback (non-first) line -- that is not the device's reported arch"
else
    log_info "OK: a later (fallback) line does not count as a native match"
fi

echo

echo "=== native_arch_matches never mutates its input (pure function contract) ==="

BEFORE="mips_24kc"
native_arch_matches "${BEFORE}" "mips_24kc" >/dev/null 2>&1 || true
assert_eq "native_arch_matches does not mutate its native_line argument" "mips_24kc" "${BEFORE}"

harness_finish "tests/apk/install-native-verify.sh"
