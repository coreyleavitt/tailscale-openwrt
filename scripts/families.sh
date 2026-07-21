#!/bin/sh
# scripts/families.sh
#
# Slice S1a (RFC docs/rfc-apk-arch-coverage.md §5.2): "family" is a
# COMPUTED grouping key over each arch row's own build tuple
# (goarch/goarm/gomips/gomips64/go386), never an authored foreign key.
# This script is the single place that mnemonic table lives:
#
#   families.sh --id-for <goarch> <goarm> <gomips> <gomips64> <go386>
#       Pure function: build tuple -> stable mnemonic family id (one of
#       the 14 in the RFC §4 table). Content-derived, insertion-order-
#       independent by construction (no positional/group_by ordering is
#       involved at all -- see round-2 D-SEV1/F-SEV3). Hard-fails (exit
#       1, stderr message, nothing on stdout) on a tuple that matches none
#       of the 14 known families -- a new family is a deliberate, reviewed
#       addition to the case statement below, never a silent generic id.
#
#   families.sh --with-ci [arches.json]
#       Emits one JSON row per family PRESENT in arches.json, each
#       carrying that family's CI-boot representative (`verify`, an arch
#       NAME string) + its rootfs pin (rootfs_target/rootfs_url/
#       rootfs_sha256). This is a derived VIEW, not per-arch columns
#       (round-2 D-SEV2) -- it is where the "exactly one verify arch per
#       family, and it must itself be a bootable arch string" invariant is
#       enforced (hard-fails if a family has no row carrying a real rootfs
#       pin). "Bootable" is operationally defined, in the current schema,
#       as "carries a non-empty rootfs_target/rootfs_url/rootfs_sha256" --
#       the same fields tests/apk/rootfs.sh and qemu.sh already key off of
#       to actually boot an arch under qemu.
#
#       If more than one row in a family carries a rootfs pin, the
#       lexicographically-first arch NAME is the deterministic tie-break
#       (content-derived, not row-order-derived) -- S1a's 4-row table never
#       exercises this (1 arch per family today); S1b's widen may.
#
#   families.sh --validate [arches.json]
#       The schema guard (round-2 P-SEV3): every row's build tuple must
#       map to a known family id (via --id-for; hard-fails on unmapped,
#       naming the offending arch), and goarch/float/endian/gomips/
#       gomips64/go386/tier must each be one of a fixed vocabulary. Prints
#       one FAIL line per violation and exits non-zero if any are found;
#       otherwise prints a one-line OK summary and exits 0.
#
# POSIX sh only (mirrors scripts/select-matrix.sh's style/no-bashisms).
#
# Usage:
#   scripts/families.sh --id-for <goarch> <goarm> <gomips> <gomips64> <go386>
#   scripts/families.sh --with-ci [arches.json]
#   scripts/families.sh --validate [arches.json]

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)

usage() {
    cat >&2 <<'EOF'
Usage:
  families.sh --id-for <goarch> <goarm> <gomips> <gomips64> <go386>
  families.sh --with-ci [arches.json]
  families.sh --validate [arches.json]
EOF
}

# id_for goarch goarm gomips gomips64 go386
#
# The 14-family mnemonic table (RFC §4). Exact-match on a colon-joined key
# (not a glob), so no tuple can accidentally match more than one family and
# no partial tuple silently falls through. Unmapped -> hard-fail (return 1)
# with a stderr diagnostic naming the offending tuple; caller decides what
# (if anything) to print on stdout, but this function itself prints nothing
# to stdout on failure.
id_for() {
    _goarch="$1"; _goarm="$2"; _gomips="$3"; _gomips64="$4"; _go386="$5"
    _key="${_goarch}:${_goarm}:${_gomips}:${_gomips64}:${_go386}"

    case "${_key}" in
        "arm64::::")             echo "A64" ;;
        "arm:7:::")              echo "A7HF" ;;
        "arm:6:::")              echo "A6HF" ;;
        "arm:5:::")              echo "ASOFT" ;;
        "mips::softfloat::")     echo "M32BE" ;;
        "mipsle::softfloat::")   echo "M32LE" ;;
        "mipsle::hardfloat::")   echo "M32LEHF" ;;
        "mips64:::hardfloat:")   echo "M64BE" ;;
        "mips64le:::hardfloat:") echo "M64LE" ;;
        "386::::sse2")           echo "X86SSE2" ;;
        "386::::softfloat")      echo "X86SOFT" ;;
        "amd64::::")             echo "AMD64" ;;
        "riscv64::::")           echo "RV64" ;;
        "loong64::::")           echo "LOONG64" ;;
        *)
            echo "families.sh: unmapped build tuple (goarch='${_goarch}' goarm='${_goarm}' gomips='${_gomips}' gomips64='${_gomips64}' go386='${_go386}') -- not one of the 14 known families" >&2
            return 1
            ;;
    esac
}

cmd_id_for() {
    [ $# -eq 5 ] || { usage; exit 1; }
    id_for "$1" "$2" "$3" "$4" "$5"
}

cmd_with_ci() {
    _arches_json="${1:-${REPO_ROOT}/arches.json}"
    if [ ! -f "${_arches_json}" ]; then
        echo "families.sh: ${_arches_json} not found" >&2
        exit 1
    fi

    _count=$(jq 'length' "${_arches_json}")
    _i=0
    _rows_file=$(mktemp)
    trap 'rm -f "${_rows_file}"' EXIT

    while [ "${_i}" -lt "${_count}" ]; do
        _row=$(jq -c ".[${_i}]" "${_arches_json}")
        _i=$((_i + 1))

        _name=$(echo "${_row}" | jq -r '.name')

        # infeasible rows (reason != null) have no family at all -- the
        # Appendix's own `family` column is empty for them -- so they are
        # excluded here, same as the family-count check in --validate.
        _reason=$(echo "${_row}" | jq -r '.reason // empty')
        if [ -n "${_reason}" ]; then
            continue
        fi

        _goarch=$(echo "${_row}" | jq -r '.goarch // ""')
        _goarm=$(echo "${_row}" | jq -r '.goarm // ""')
        _gomips=$(echo "${_row}" | jq -r '.gomips // ""')
        _gomips64=$(echo "${_row}" | jq -r '.gomips64 // ""')
        _go386=$(echo "${_row}" | jq -r '.go386 // ""')

        _family=$(id_for "${_goarch}" "${_goarm}" "${_gomips}" "${_gomips64}" "${_go386}") || {
            echo "families.sh --with-ci: arch '${_name}' has an unmapped build tuple" >&2
            exit 1
        }

        _rootfs_target=$(echo "${_row}" | jq -r '.rootfs_target // ""')
        _rootfs_url=$(echo "${_row}" | jq -r '.rootfs_url // ""')
        _rootfs_sha256=$(echo "${_row}" | jq -r '.rootfs_sha256 // ""')

        _bootable="false"
        if [ -n "${_rootfs_target}" ] && [ -n "${_rootfs_url}" ] && [ -n "${_rootfs_sha256}" ]; then
            _bootable="true"
        fi

        jq -n \
            --arg family "${_family}" \
            --arg name "${_name}" \
            --arg bootable "${_bootable}" \
            --arg rootfs_target "${_rootfs_target}" \
            --arg rootfs_url "${_rootfs_url}" \
            --arg rootfs_sha256 "${_rootfs_sha256}" \
            '{family: $family, name: $name, bootable: ($bootable == "true"),
              rootfs_target: $rootfs_target, rootfs_url: $rootfs_url, rootfs_sha256: $rootfs_sha256}' \
            >> "${_rows_file}"
    done

    # Group the per-arch rows by family; within each family, the
    # verify/rootfs representative is the lexicographically-first
    # bootable-candidate arch name (deterministic, content-derived --
    # never row-order-derived). Hard-fail if a family has NO bootable
    # candidate at all: --with-ci's whole point is to hand back something
    # CI can actually boot.
    jq -s '
        group_by(.family)
        | map(
            . as $rows
            | ($rows[0].family) as $family
            | ([$rows[] | select(.bootable)] | sort_by(.name)) as $candidates
            | if ($candidates | length) == 0
              then error("families.sh --with-ci: family " + $family + " has no bootable rootfs-pinned arch")
              else $candidates[0] as $v
                | {family: $family, verify: $v.name,
                   rootfs_target: $v.rootfs_target, rootfs_url: $v.rootfs_url, rootfs_sha256: $v.rootfs_sha256}
              end
          )
        | sort_by(.family)
    ' "${_rows_file}"
}

cmd_validate() {
    _arches_json="${1:-${REPO_ROOT}/arches.json}"
    if [ ! -f "${_arches_json}" ]; then
        echo "families.sh: ${_arches_json} not found" >&2
        exit 1
    fi

    _fail=0
    _count=$(jq 'length' "${_arches_json}")
    _i=0
    _errfile=$(mktemp)
    _familiesfile=$(mktemp)
    trap 'rm -f "${_errfile}" "${_familiesfile}"' EXIT

    while [ "${_i}" -lt "${_count}" ]; do
        _row=$(jq -c ".[${_i}]" "${_arches_json}")
        _idx="${_i}"
        _i=$((_i + 1))

        _name=$(echo "${_row}" | jq -r '.name // empty')
        if [ -z "${_name}" ]; then
            _name="<row ${_idx}>"
        fi
        _goarch=$(echo "${_row}" | jq -r '.goarch // ""')
        _goarm=$(echo "${_row}" | jq -r '.goarm // ""')
        _gomips=$(echo "${_row}" | jq -r '.gomips // ""')
        _gomips64=$(echo "${_row}" | jq -r '.gomips64 // ""')
        _go386=$(echo "${_row}" | jq -r '.go386 // ""')
        _endian=$(echo "${_row}" | jq -r '.endian // ""')
        _float=$(echo "${_row}" | jq -r '.float // ""')
        _tier=$(echo "${_row}" | jq -r '.tier // ""')

        # `tier == infeasible` rows (reason != null) are deliberately built
        # from a blank tuple (goarch/goarm/gomips/gomips64/go386 all "") --
        # the Appendix's `family` column is empty for them by definition, so
        # neither the goarch-vocabulary check nor the tuple->family mapping
        # applies. Every other tier is a real, buildable tuple and both
        # checks still apply in full.
        if [ "${_tier}" != "infeasible" ]; then
            case "${_goarch}" in
                arm64|arm|mips|mipsle|mips64|mips64le|386|amd64|riscv64|loong64) ;;
                *)
                    echo "FAIL: ${_name}: goarch '${_goarch}' is not in the known vocabulary" >&2
                    _fail=1
                    ;;
            esac
        fi

        case "${_float}" in
            hard|soft) ;;
            *)
                echo "FAIL: ${_name}: float '${_float}' is not one of hard|soft" >&2
                _fail=1
                ;;
        esac

        case "${_endian}" in
            little|big) ;;
            *)
                echo "FAIL: ${_name}: endian '${_endian}' is not one of little|big" >&2
                _fail=1
                ;;
        esac

        case "${_gomips}" in
            ""|softfloat|hardfloat) ;;
            *)
                echo "FAIL: ${_name}: gomips '${_gomips}' is not one of ''|softfloat|hardfloat" >&2
                _fail=1
                ;;
        esac

        case "${_gomips64}" in
            ""|softfloat|hardfloat) ;;
            *)
                echo "FAIL: ${_name}: gomips64 '${_gomips64}' is not one of ''|softfloat|hardfloat" >&2
                _fail=1
                ;;
        esac

        case "${_go386}" in
            ""|sse2|softfloat) ;;
            *)
                echo "FAIL: ${_name}: go386 '${_go386}' is not one of ''|sse2|softfloat" >&2
                _fail=1
                ;;
        esac

        case "${_tier}" in
            core|extended|infeasible) ;;
            *)
                echo "FAIL: ${_name}: tier '${_tier}' is not one of core|extended|infeasible" >&2
                _fail=1
                ;;
        esac

        if [ "${_tier}" = "infeasible" ]; then
            : # no tuple to map -- infeasible rows have no family (Appendix)
        elif _family=$(id_for "${_goarch}" "${_goarm}" "${_gomips}" "${_gomips64}" "${_go386}" 2>"${_errfile}"); then
            echo "${_family}" >> "${_familiesfile}"
        else
            echo "FAIL: ${_name}: $(cat "${_errfile}")" >&2
            _fail=1
        fi
    done

    # Schema guard (round-2 P-SEV3): the feasible rows (core + extended --
    # everything with a real, mapped tuple) must group into EXACTLY the 14
    # families in the RFC §4 table, no more, no fewer. group_by can't tell
    # "deliberately distinct" from "accidentally distinct" (a typo'd enum
    # value silently mints a spurious 1-arch family), so this is a hard
    # count assertion, not just "every row mapped to something".
    _family_count=$(sort -u "${_familiesfile}" | wc -l | tr -d ' ')
    if [ "${_fail}" -eq 0 ] && [ "${_family_count}" -ne 14 ]; then
        echo "FAIL: derived family count is ${_family_count}, expected exactly 14 (families: $(sort -u "${_familiesfile}" | tr '\n' ' '))" >&2
        _fail=1
    fi

    if [ "${_fail}" -ne 0 ]; then
        echo "families.sh --validate: FAILED" >&2
        exit 1
    fi
    echo "families.sh --validate: OK (${_count} row(s), ${_family_count} families, all tuples mapped, all enums valid)"
}

MODE="${1:-}"
case "${MODE}" in
    --id-for)
        shift
        cmd_id_for "$@"
        ;;
    --with-ci)
        shift
        cmd_with_ci "${1:-}"
        ;;
    --validate)
        shift
        cmd_validate "${1:-}"
        ;;
    *)
        usage
        exit 1
        ;;
esac
