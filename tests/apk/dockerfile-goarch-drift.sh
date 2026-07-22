#!/bin/sh
# tests/apk/dockerfile-goarch-drift.sh
#
# M6 (code-review finding, docs/rfc-apk-arch-coverage.md §5.2 "no authored
# duplicate + a drift-guard test"): the exact GOARCH allow-list literal
# `arm64|arm|mips|mipsle|mips64|mips64le|386|amd64|riscv64|loong64` is
# authored TWICE, unavoidably -- once in scripts/families.sh's
# cmd_validate (the host-side schema guard) and once in
# tailscale-package/Dockerfile's build-stage hard-fail guard (which runs
# INSIDE the docker build, with no access to families.sh -- there is no
# runtime function to share across that boundary). A GOARCH added to one
# and forgotten in the other is a live bug: either a new arch silently
# fails Dockerfile's hard-fail guard while --validate accepts it (or vice
# versa).
#
# This is not a "route through one accessor" fix (M4/M5's shape) -- it's a
# drift test: extract the vocabulary from BOTH authored sites (via each
# file's own GOARCH_VOCAB_CANONICAL marker comment, not by re-hardcoding
# the vocabulary in this test itself, mirroring tests/apk/
# install-arch-block.sh's byte-identity discipline) and assert set-equality.
# Neither side is treated as "more canonical" than the other by this test
# -- it only ever proves "these two agree," so it stays useful even as the
# vocabulary itself evolves (e.g. a hypothetical future Go GOARCH addition
# lands in both places together, in the same commit).
#
# No docker build needed -- pure grep/sh, mirroring families.sh/
# select-matrix.sh's own hermetic test style.
#
# Usage: sh tests/apk/dockerfile-goarch-drift.sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/../.." && pwd)
FAMILIES_SH="${REPO_ROOT}/scripts/families.sh"
DOCKERFILE="${REPO_ROOT}/tailscale-package/Dockerfile"

# shellcheck source=tests/apk/lib.sh
. "${SCRIPT_DIR}/lib.sh"

if [ ! -f "${FAMILIES_SH}" ]; then
    log_fail "scripts/families.sh not found at ${FAMILIES_SH}"
    harness_finish "tests/apk/dockerfile-goarch-drift.sh"
    exit "${FAIL}"
fi
if [ ! -f "${DOCKERFILE}" ]; then
    log_fail "tailscale-package/Dockerfile not found at ${DOCKERFILE}"
    harness_finish "tests/apk/dockerfile-goarch-drift.sh"
    exit "${FAIL}"
fi

# extract_goarch_vocab <file> -- find the GOARCH_VOCAB_CANONICAL marker
# comment, then scan forward for the first line shaped like a POSIX `case`
# arm listing 2+ pipe-separated bare words ending in `) ;;` (works whether
# that line is immediately after the marker, as in families.sh, or a few
# lines later, as in the Dockerfile where the marker sits above the `RUN
# case "${GOARCH}" in \` line itself -- a shell comment cannot be spliced
# into the middle of a backslash-continued Dockerfile RUN instruction).
# Strips everything from the first `)` onward and any leading whitespace,
# then splits on `|` and sorts -- so this asserts SET equality, not
# authored order.
extract_goarch_vocab() {
    _file="$1"
    awk '
        found {
            line = $0
            gsub(/^[ \t]+/, "", line)
            if (line ~ /^[a-z0-9]+(\|[a-z0-9]+)+\)/) {
                print line
                exit
            }
            next
        }
        /GOARCH_VOCAB_CANONICAL/ { found = 1 }
    ' "${_file}" | sed -E 's/\).*$//' | tr '|' '\n' | sort -u
}

echo "=== M6: extract GOARCH vocab from both authored sites ==="

FAMILIES_VOCAB=$(extract_goarch_vocab "${FAMILIES_SH}")
DOCKERFILE_VOCAB=$(extract_goarch_vocab "${DOCKERFILE}")

if [ -z "${FAMILIES_VOCAB}" ]; then
    log_fail "could not extract a GOARCH vocabulary from ${FAMILIES_SH} (GOARCH_VOCAB_CANONICAL marker missing or moved?)"
else
    log_info "OK: extracted families.sh vocab: $(echo "${FAMILIES_VOCAB}" | tr '\n' ' ')"
fi

if [ -z "${DOCKERFILE_VOCAB}" ]; then
    log_fail "could not extract a GOARCH vocabulary from ${DOCKERFILE} (GOARCH_VOCAB_CANONICAL marker missing or moved?)"
else
    log_info "OK: extracted Dockerfile vocab: $(echo "${DOCKERFILE_VOCAB}" | tr '\n' ' ')"
fi

echo

echo "=== M6: the two authored GOARCH vocabularies are set-identical ==="

assert_eq "families.sh cmd_validate's GOARCH vocab == Dockerfile's build-stage GOARCH vocab" \
    "${FAMILIES_VOCAB}" "${DOCKERFILE_VOCAB}"

echo

echo "=== M6: sanity -- the extracted vocab is non-trivial (not an empty/vacuous match) ==="

VOCAB_COUNT=$(echo "${FAMILIES_VOCAB}" | sed '/^$/d' | wc -l | tr -d ' ')
if [ "${VOCAB_COUNT}" -ge 8 ]; then
    log_info "OK: extracted ${VOCAB_COUNT} GOARCH values (expected the 10 known Go GOARCHes this repo builds)"
else
    log_fail "extracted vocab has only ${VOCAB_COUNT} entries -- extraction likely broken, not a genuine small vocab"
fi

echo

harness_finish "tests/apk/dockerfile-goarch-drift.sh"
