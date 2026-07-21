#!/bin/sh
# scripts/release-checksums.sh
#
# Factored out of the `release` workflow job's inline
# `sha256sum *.ipk tailscaled_*` step (slice C4, RFC docs/rfc-apk-builds.md
# §4.3) so "does SHA256SUMS list every expected release asset with a
# correct hash" is locally runnable and testable
# (tests/apk/release-checksums.sh) without a live release. Covers the
# original ipk-only patterns UNCHANGED (`*.ipk`, `tailscaled_*` -- same
# glob set the inline step used, so re-hashing the same bytes produces
# byte-identical SHA256SUMS lines for the ipk assets, per the RFC's "keep
# ipk release behavior unchanged" discipline) PLUS, new in C4, `*.apk` and
# `*.pem` (the EC public key) -- so one SHA256SUMS covers every asset
# attached to the release, ipk or apk (RFC §4.3 "Extend SHA256SUMS ... to
# cover the .apks").
#
# Usage: scripts/release-checksums.sh <assets-dir> [output-file]
#   <assets-dir>   directory containing the release assets to checksum.
#                   Filenames land in SHA256SUMS relative to this dir
#                   (matching the original `cd packages && sha256sum ...`
#                   convention), so a plain `sha256sum -c SHA256SUMS` run
#                   from inside <assets-dir> verifies unmodified.
#   [output-file]  defaults to <assets-dir>/SHA256SUMS
#
# Only checksums specific known release-asset patterns -- never a blanket
# `sha256sum *` -- so SHA256SUMS never folds in its own hash on a re-run
# (the two-softprops-calls upsert scenario, §4.3/§4.6) and generated
# metadata like sbom.spdx.json is never accidentally included (neither was
# checksummed by the original ipk-only behavior).
set -eu

ASSETS_DIR="${1:?usage: release-checksums.sh <assets-dir> [output-file]}"
OUTPUT="${2:-${ASSETS_DIR}/SHA256SUMS}"

[ -d "${ASSETS_DIR}" ] || {
    echo "release-checksums.sh: ${ASSETS_DIR} is not a directory" >&2
    exit 1
}

TMP=$(mktemp)
trap 'rm -f "${TMP}"' EXIT

(
    cd "${ASSETS_DIR}"
    for pattern in '*.ipk' 'tailscaled_*' '*.apk' '*.pem'; do
        for f in ${pattern}; do
            # Unmatched glob leaves the literal pattern string -- skip it.
            [ -e "${f}" ] || continue
            sha256sum "${f}"
        done
    done
) > "${TMP}"

if [ ! -s "${TMP}" ]; then
    echo "release-checksums.sh: no matching release assets found under ${ASSETS_DIR}" >&2
    exit 1
fi

# Deterministic order (sha256sum output is "<hash>  <filename>"; sort by
# the filename field) -- makes the output diff-stable across CI runs and
# easy to assert against in tests.
sort -k2 "${TMP}" > "${OUTPUT}"
