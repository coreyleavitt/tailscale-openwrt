#!/bin/sh
# scripts/select-matrix.sh
#
# Selects the per-arch/per-family build matrix from arches.json,
# event-conditionally (RFC docs/rfc-apk-builds.md §5 "CI cost / emulation
# policy" + §6 slice A5a):
#
#   pull_request        -> cheap PR signal: the canary arch(es) only
#   anything else        -> the gated production set (varies by mode, below)
#     (workflow_dispatch is the only event that currently fires
#     build-tailscale.yaml, per check-releases.yaml)
#
# Emits a compact JSON array of full arch objects (same shape as
# arches.json entries) for the flat modes, so a caller (CI matrix step or a
# test) has every field -- rootfs_url/rootfs_sha256/container_arch/tier/etc
# -- without a second lookup.
#
# **S1.5/S5a multi-output contract (RFC docs/rfc-apk-arch-coverage.md §5.3
# round-2 F-SEV2/P-SEV2, §5.8 the gate-flip).** Today's Dockerfile/apk feed
# only just proved itself on all 14 families (S2-S4); the migration-safety
# gate (§5.8) is what decides whether that widened set actually ships. Three
# named modes, each independently selectable:
#
#   --ipk-arches (default, no flag -- kept for the existing call sites that
#       predate this multi-output split)
#       The HISTORICAL/legacy set: non-PR -> `tier == "core"`. ipk must NEVER
#       widen (RFC non-goal: "OpenWrt <=24.10 stays ipk") -- this mode's gate
#       is deliberately NOT the §5.8 gate-flip target and stays pinned to
#       `tier=="core"` forever, independent of compile_families/publish_arches
#       below.
#   --compile-families
#       `build-apk` compiles ONCE PER FAMILY (14 family builds), then
#       packages that family's arches in a shell loop (no second matrix
#       stage). Non-PR gate: `reason == null` (every FEASIBLE arch --
#       `tier=="core"` or `tier=="extended"`, i.e. the §5.8 gate-flip: the
#       `tier=="core"`-only filter this mode used to share with --ipk-arches
#       is DROPPED here). `tier=="infeasible"` rows are always excluded (Go
#       cannot build them at all).
#   --publish-arches
#       The feed-publish loop's arch set. Non-PR gate: same `reason == null`
#       widened set as --compile-families (the other half of the §5.8
#       gate-flip) -- every feasible arch's signed apk gets published, not
#       just the 4 historical `tier=="core"` ones. Each row keeps its `tier`
#       field so a caller can still tell core from extended (RFC §5.4's
#       core/extended atomicity split, S5b, reads this field; NOT
#       implemented by this script itself).
#
# The PR branch is IDENTICAL across all three modes -- keyed STRICTLY on
# `canary == true` (RFC §5.3 round-2 P-SEV2/F-SEV2) -- the old `.canary ==
# true or .container_arch == "aarch64"` OR-clause is deleted. Once A64 has
# multiple `aarch64` rows, that OR-clause would pull ALL of them into every
# PR emulation leg; canary is the single per-arch field that names exactly
# which arch(es) are the PR signal, independent of how many share a
# container_arch.
#
# This is the single implementation of the matrix-selection logic: the
# workflow calls it as a step (so the conditioning isn't reimplemented as an
# untestable inline GitHub Actions expression), and several tests/apk/*.sh
# scripts call it directly to assert the selection without a live GitHub
# Actions run.
#
# Family rows (--compile-families) carry:
#   { "family": "A64", "goarch": "arm64", "goarm": "", "gomips": "",
#     "gomips64": "", "go386": "", "arches": ["aarch64_cortex-a53", ...] }
# `family`/the build-tuple fields come from scripts/families.sh --id-for
# (the single tested pure fn -- never re-derived here), so a family id is
# never authored twice. `arches` is every gated row's name in that family,
# sorted (content-derived, not row-order-derived, mirroring families.sh
# --with-ci's own tie-break convention) -- this is what build-apk's in-job
# packaging loop iterates.
#
# Usage:
#   scripts/select-matrix.sh <event_name> [--ipk-arches] [arches_json_path]
#   scripts/select-matrix.sh <event_name> --compile-families [arches_json_path]
#   scripts/select-matrix.sh <event_name> --publish-arches [arches_json_path]
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
FAMILIES_SH="${SCRIPT_DIR}/families.sh"

EVENT_NAME="${1:?usage: select-matrix.sh <event_name> [--ipk-arches|--compile-families|--publish-arches] [arches_json_path]}"
shift

MODE="ipk_arches"
case "${1:-}" in
    --ipk-arches) MODE="ipk_arches"; shift ;;
    --compile-families) MODE="compile_families"; shift ;;
    --publish-arches) MODE="publish_arches"; shift ;;
esac

ARCHES_JSON="${1:-${REPO_ROOT}/arches.json}"

if [ ! -f "${ARCHES_JSON}" ]; then
    echo "select-matrix.sh: ${ARCHES_JSON} not found" >&2
    exit 1
fi

if [ "${EVENT_NAME}" = "pull_request" ]; then
    GATE_FILTER='.canary == true'
else
    case "${MODE}" in
        ipk_arches)
            # RFC non-goal: ipk must NOT widen -- pinned to tier=="core"
            # regardless of the compile_families/publish_arches gate-flip.
            GATE_FILTER='.tier == "core"'
            ;;
        compile_families | publish_arches)
            # S5a gate-flip (RFC §5.8): every FEASIBLE arch, core-only filter
            # dropped. tier=="infeasible" rows (reason != null) are still
            # excluded -- Go cannot build them at all.
            GATE_FILTER='.reason == null'
            ;;
    esac
fi

if [ "${MODE}" = "ipk_arches" ] || [ "${MODE}" = "publish_arches" ]; then
    jq -c "[.[] | select(${GATE_FILTER})]" "${ARCHES_JSON}"
    exit 0
fi

# --compile-families from here down.

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
        echo "select-matrix.sh --compile-families: arch '${NAME}' has an unmapped build tuple" >&2
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
