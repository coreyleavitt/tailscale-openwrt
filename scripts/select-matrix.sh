#!/bin/sh
# scripts/select-matrix.sh
#
# Selects the per-arch build matrix from arches.json, event-conditionally
# (RFC docs/rfc-apk-builds.md §5 "CI cost / emulation policy" + §6 slice A5a):
#
#   pull_request        -> cheap PR signal: the canary arch(es) only
#   anything else        -> the `tier=="core"` migration-safety-gated set
#     (workflow_dispatch is the only event that currently fires
#     build-tailscale.yaml, per check-releases.yaml)
#
# Emits a compact JSON array of full arch objects (same shape as
# arches.json entries), so a caller (CI matrix step or a test) has every
# field -- rootfs_url/rootfs_sha256/container_arch/etc -- without a second
# lookup.
#
# **Migration-safety gate (RFC docs/rfc-apk-arch-coverage.md §5.8, slice
# S1b).** arches.json was widened from 4 to 35 rows (the Appendix's full
# arch table) in S1b, but the Dockerfile's build stage is still S2's
# not-yet-landed data-driven rewrite -- until S2/S3/S4 land, every non-legacy
# arch would silently mis-build as 32-bit MIPS. The `tier` field is the gate:
# the non-PR branch filters to `tier=="core"` (the 4 historical, hand-proven
# arches), NOT the full table, so the widened `extended`/`infeasible` rows
# sit inert (they compile-smoke in S2 but never reach this selector's output
# until the S5 gate-flip deliberately drops this filter). This is the
# MINIMAL inert-gate for S1b -- the multi-output contract
# (ipk_arches/compile_families/publish_arches/verify_families) is deferred
# to S1.5/S1c/S7a; this branch keeps today's single-array shape.
#
# The PR branch keys STRICTLY on `canary == true` (RFC §5.3 round-2
# P-SEV2/F-SEV2) -- the old `.canary == true or .container_arch ==
# "aarch64"` OR-clause is deleted. Once A64 grows multiple `aarch64`
# rows (S1b's widen), that OR-clause would pull ALL of them into every PR
# emulation leg; canary is the single per-arch field that names exactly
# which arch(es) are the PR signal, independent of how many share a
# container_arch.
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
    jq -c '[.[] | select(.canary == true)]' "${ARCHES_JSON}"
else
    jq -c '[.[] | select(.tier == "core")]' "${ARCHES_JSON}"
fi
