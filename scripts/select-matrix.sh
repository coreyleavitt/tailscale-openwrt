#!/bin/sh
# scripts/select-matrix.sh
#
# Selects the per-arch build matrix from arches.json, event-conditionally
# (RFC docs/rfc-apk-builds.md §5 "CI cost / emulation policy" + §6 slice A5a):
#
#   pull_request        -> cheap PR signal: aarch64 + the MIPS canary only
#   anything else        -> full matrix (workflow_dispatch, release, ...)
#     (workflow_dispatch is the only event that currently fires
#     build-tailscale.yaml, per check-releases.yaml)
#
# Emits a compact JSON array of full arch objects (same shape as
# arches.json entries), so a caller (CI matrix step or a test) has every
# field -- rootfs_url/rootfs_sha256/container_arch/etc -- without a second
# lookup.
#
# "aarch64" is selected via the container_arch field (=="aarch64"), not by
# hardcoding the arch name, so this stays correct if arches.json's naming
# changes. The MIPS canary is selected via the canary field (arches.json's
# single source of truth for "which arch is the canary" -- currently
# mips_24kc).
#
# This is the single implementation of the matrix-selection logic: the
# workflow calls it as a step (so the conditioning isn't reimplemented as an
# untestable inline GitHub Actions expression), and tests/apk/qemu.sh calls
# it directly to assert the selection without a live GitHub Actions run.
#
# Usage: scripts/select-matrix.sh <event_name> [arches_json_path]
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)

EVENT_NAME="${1:?usage: select-matrix.sh <event_name> [arches_json_path]}"
ARCHES_JSON="${2:-${REPO_ROOT}/arches.json}"

if [ ! -f "${ARCHES_JSON}" ]; then
    echo "select-matrix.sh: ${ARCHES_JSON} not found" >&2
    exit 1
fi

if [ "${EVENT_NAME}" = "pull_request" ]; then
    jq -c '[.[] | select(.canary == true or .container_arch == "aarch64")]' "${ARCHES_JSON}"
else
    jq -c '.' "${ARCHES_JSON}"
fi
