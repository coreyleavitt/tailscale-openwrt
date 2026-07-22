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
# **Families view (RFC §5.3/S4).** `build-apk` compiles ONCE PER FAMILY (14
# family builds), then packages that family's arches in a shell loop --
# never a second per-arch matrix (RFC §5.3 "no second matrix stage"). Pass
# `--families` (immediately after the event name) to get that view instead
# of the flat per-arch array: one JSON row per family PRESENT in the SAME
# gated set the plain (non---families) mode returns (non-PR ->
# `tier=="core"`; PR -> `canary==true`), each row carrying:
#   { "family": "A64", "goarch": "arm64", "goarm": "", "gomips": "",
#     "gomips64": "", "go386": "", "arches": ["aarch64_cortex-a53"] }
# `family`/the build-tuple fields come from scripts/families.sh --id-for
# (the single tested pure fn -- never re-derived here), so a family id is
# never authored twice. `arches` is every gated row's name in that family,
# sorted (content-derived, not row-order-derived, mirroring families.sh
# --with-ci's own tie-break convention) -- this is what build-apk's in-job
# packaging loop iterates. Under today's core-gating this yields 4 families
# (A64/ASOFT/M32BE/M32LE), each carrying its single core arch; the S5a gate
# flip (dropping the tier=="core" filter here) is what widens this to all
# 14 families/30 arches -- NOT this slice.
#
# Usage:
#   scripts/select-matrix.sh <event_name> [arches_json_path]
#   scripts/select-matrix.sh <event_name> --families [arches_json_path]
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
FAMILIES_SH="${SCRIPT_DIR}/families.sh"

EVENT_NAME="${1:?usage: select-matrix.sh <event_name> [--families] [arches_json_path]}"
shift

MODE="arches"
if [ "${1:-}" = "--families" ]; then
    MODE="families"
    shift
fi

ARCHES_JSON="${1:-${REPO_ROOT}/arches.json}"

if [ ! -f "${ARCHES_JSON}" ]; then
    echo "select-matrix.sh: ${ARCHES_JSON} not found" >&2
    exit 1
fi

if [ "${EVENT_NAME}" = "pull_request" ]; then
    GATE_FILTER='.canary == true'
else
    GATE_FILTER='.tier == "core"'
fi

if [ "${MODE}" = "arches" ]; then
    jq -c "[.[] | select(${GATE_FILTER})]" "${ARCHES_JSON}"
    exit 0
fi

if [ ! -x "${FAMILIES_SH}" ]; then
    echo "select-matrix.sh: ${FAMILIES_SH} not found or not executable" >&2
    exit 1
fi

GATED=$(jq -c "[.[] | select(${GATE_FILTER})]" "${ARCHES_JSON}")
COUNT=$(echo "${GATED}" | jq 'length')
I=0
ROWS_FILE=$(mktemp)
trap 'rm -f "${ROWS_FILE}"' EXIT

while [ "${I}" -lt "${COUNT}" ]; do
    ROW=$(echo "${GATED}" | jq -c ".[${I}]")
    I=$((I + 1))

    NAME=$(echo "${ROW}" | jq -r '.name')
    GOARCH=$(echo "${ROW}" | jq -r '.goarch // ""')
    GOARM=$(echo "${ROW}" | jq -r '.goarm // ""')
    GOMIPS=$(echo "${ROW}" | jq -r '.gomips // ""')
    GOMIPS64=$(echo "${ROW}" | jq -r '.gomips64 // ""')
    GO386=$(echo "${ROW}" | jq -r '.go386 // ""')

    FAMILY=$("${FAMILIES_SH}" --id-for "${GOARCH}" "${GOARM}" "${GOMIPS}" "${GOMIPS64}" "${GO386}") || {
        echo "select-matrix.sh --families: arch '${NAME}' has an unmapped build tuple" >&2
        exit 1
    }

    jq -n \
        --arg family "${FAMILY}" \
        --arg name "${NAME}" \
        --arg goarch "${GOARCH}" \
        --arg goarm "${GOARM}" \
        --arg gomips "${GOMIPS}" \
        --arg gomips64 "${GOMIPS64}" \
        --arg go386 "${GO386}" \
        '{family: $family, name: $name, goarch: $goarch, goarm: $goarm,
          gomips: $gomips, gomips64: $gomips64, go386: $go386}' \
        >> "${ROWS_FILE}"
done

# Group by family (content-derived, not insertion/row-order -- every row in
# a family carries an identical build tuple by construction, so `.[0]`'s
# tuple fields are the family's tuple). `arches` is sorted so the output is
# independent of arches.json's row order.
jq -s '
    group_by(.family)
    | map({
        family: .[0].family,
        goarch: .[0].goarch,
        goarm: .[0].goarm,
        gomips: .[0].gomips,
        gomips64: .[0].gomips64,
        go386: .[0].go386,
        arches: ([.[].name] | sort)
      })
    | sort_by(.family)
' "${ROWS_FILE}"
