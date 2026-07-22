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
# **S1.5/S5a/S7a multi-output contract (RFC docs/rfc-apk-arch-coverage.md
# §5.3 round-2 F-SEV2/P-SEV2, §5.8 the gate-flip, §5.6 CI verification).**
# Today's Dockerfile/apk feed only just proved itself on all 14 families
# (S2-S4); the migration-safety gate (§5.8) is what decides whether that
# widened set actually ships. Four named modes, each independently
# selectable:
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
#   --verify-families
#       S7a (RFC §5.6): the qemu-verify / native-arch-install-verify job's
#       matrix. Non-PR: one row per BOOTABLE family (a family with a
#       `verify: true` arch row, per scripts/families.sh --with-ci --
#       today the 10 in RFC §5.6, e.g. A6HF/ASOFT/M32LEHF/RV64 are
#       genuinely unbootable and excluded, the S7b "unverified" tier).
#       Each row carries the verify arch NAME + its build tuple +
#       rootfs_url/rootfs_sha256/container_arch -- everything the CI job
#       needs without a second arches.json lookup. PR: the SAME
#       canary-only policy as the other three modes, applied by filtering
#       down to whichever bootable row(s) carry a canary arch as their
#       `verify` name (hard-fails if a canary arch's family isn't
#       bootable -- RFC §5.2's canary-subseteq-verify invariant).
#
# The PR branch is IDENTICAL across all four modes -- keyed STRICTLY on
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
# `family`/the build-tuple fields come from scripts/families.sh
# --compile-families (M5, code-review finding: this mode delegates the
# gated-rows-to-family-groups transform wholesale, built on the same
# build_family_rows() grouping --with-ci/--unverified-arches share -- never
# an independently re-derived grouping loop here), so a family id is never
# authored twice. `arches` is every gated row's name in that family, sorted
# (content-derived, not row-order-derived, mirroring families.sh
# --with-ci's own tie-break convention) -- this is what build-apk's in-job
# packaging loop iterates.
#
# Usage:
#   scripts/select-matrix.sh <event_name> [--ipk-arches] [arches_json_path]
#   scripts/select-matrix.sh <event_name> --compile-families [arches_json_path]
#   scripts/select-matrix.sh <event_name> --publish-arches [arches_json_path]
#   scripts/select-matrix.sh <event_name> --verify-families [arches_json_path]
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
FAMILIES_SH="${SCRIPT_DIR}/families.sh"

EVENT_NAME="${1:?usage: select-matrix.sh <event_name> [--ipk-arches|--compile-families|--publish-arches|--verify-families] [arches_json_path]}"
shift

MODE="ipk_arches"
case "${1:-}" in
    --ipk-arches) MODE="ipk_arches"; shift ;;
    --compile-families) MODE="compile_families"; shift ;;
    --publish-arches) MODE="publish_arches"; shift ;;
    --verify-families) MODE="verify_families"; shift ;;
esac

ARCHES_JSON="${1:-${REPO_ROOT}/arches.json}"

if [ ! -f "${ARCHES_JSON}" ]; then
    echo "select-matrix.sh: ${ARCHES_JSON} not found" >&2
    exit 1
fi

# --ipk-arches, non-PR: RFC non-goal -- ipk must NOT widen, pinned to
# tier=="core" regardless of the compile_families/publish_arches gate-flip
# below. M4 (code-review finding): "which arches are tier==core" is
# scripts/families.sh --tier-arches's own accessor -- the single authored
# place that predicate lives -- not a second `.tier == "core"` jq literal
# here. Passing the literal string "core" (not some variable computed by
# the gate-flip logic below) keeps this exactly as pinned/independent of
# any future compile_families/publish_arches widening as before; only the
# "which arches are tier==core right now" lookup itself is shared, never
# reimplemented a 5th time (tests/apk/families.sh's M4 section
# grep-guards the other four authored sites; this one is proven identical
# by construction -- it calls the same accessor -- rather than by drift
# test).
if [ "${EVENT_NAME}" != "pull_request" ] && [ "${MODE}" = "ipk_arches" ]; then
    if [ ! -x "${FAMILIES_SH}" ]; then
        echo "select-matrix.sh: ${FAMILIES_SH} not found or not executable" >&2
        exit 1
    fi
    CORE_NAMES_JSON=$("${FAMILIES_SH}" --tier-arches core "${ARCHES_JSON}" | jq -R . | jq -s .)
    jq -c --argjson names "${CORE_NAMES_JSON}" \
        '[.[] | select(.name as $n | $names | index($n) != null)]' "${ARCHES_JSON}"
    exit 0
fi

if [ "${EVENT_NAME}" = "pull_request" ]; then
    GATE_FILTER='.canary == true'
else
    case "${MODE}" in
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

# --verify-families (S7a, RFC §5.3/§5.6): the bootable representative per
# family, from families.sh --with-ci's verify:true-flag-driven view (never
# re-derived here -- see families.sh's own header comment for why "first
# row with a rootfs pin" is the wrong inference). A family with no
# verify:true row (A6HF/ASOFT/M32LEHF/RV64 today, RFC §5.6's S7b tier) is
# simply absent from --with-ci's output -- this mode does not second-guess
# that, it passes the view through.
#
# PR event: the SAME canary-only policy as every other mode (RFC §5.3
# round-2 P-SEV2/F-SEV2), applied by filtering --with-ci's rows down to
# whichever one(s) carry a canary arch as their `verify` name -- NOT by
# re-deriving a family from `.canary`, so this stays independent of how
# many arches share a container_arch (the same regression the other three
# modes already guard). RFC §5.2's own invariant is "every canary arch's
# family must be verify-able" (canary subseteq verify) -- hard-fail here,
# loudly, if a canary arch's family is missing from the bootable view
# instead of silently shrinking the PR matrix to zero rows.
if [ "${MODE}" = "verify_families" ]; then
    if [ ! -x "${FAMILIES_SH}" ]; then
        echo "select-matrix.sh: ${FAMILIES_SH} not found or not executable" >&2
        exit 1
    fi

    WITH_CI=$("${FAMILIES_SH}" --with-ci "${ARCHES_JSON}")

    if [ "${EVENT_NAME}" = "pull_request" ]; then
        CANARY_NAMES=$(jq -c '[.[] | select(.canary == true) | .name]' "${ARCHES_JSON}")

        MISSING_CANARY=$(jq -n --argjson names "${CANARY_NAMES}" --argjson rows "${WITH_CI}" \
            '[$names[] as $n | select(([$rows[] | select(.verify == $n)] | length) == 0) | $n]')
        MISSING_COUNT=$(echo "${MISSING_CANARY}" | jq 'length')
        if [ "${MISSING_COUNT}" -gt 0 ]; then
            echo "select-matrix.sh --verify-families: canary arch(es) ${MISSING_CANARY} have no bootable (verify:true) family -- canary must be a subset of verify (RFC §5.2)" >&2
            exit 1
        fi

        echo "${WITH_CI}" | jq -c --argjson names "${CANARY_NAMES}" \
            '[.[] | select(.verify as $v | $names | index($v) != null)]'
        exit 0
    fi

    echo "${WITH_CI}" | jq -c '.'
    exit 0
fi

# --compile-families from here down. M5 (code-review finding): the "gated
# rows -> group by family -> tuple + sorted arch list" transform now
# delegates WHOLESALE to families.sh --compile-families -- built on the
# exact same build_family_rows() grouping --with-ci/--unverified-arches
# already share -- the same way --verify-families above delegates to
# families.sh --with-ci, instead of an independent "iterate rows ->
# --id-for per row (a subprocess call per arch) -> group_by" loop
# reimplemented here.

if [ ! -x "${FAMILIES_SH}" ]; then
    echo "select-matrix.sh: ${FAMILIES_SH} not found or not executable" >&2
    exit 1
fi

GATED=$(jq -c "[.[] | select(${GATE_FILTER})]" "${ARCHES_JSON}")
GATED_FILE=$(mktemp)
trap 'rm -f "${GATED_FILE}"' EXIT
echo "${GATED}" > "${GATED_FILE}"

"${FAMILIES_SH}" --compile-families "${GATED_FILE}"
