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
#       Emits one JSON row per BOOTABLE family present in arches.json (a
#       family with at least one `verify: true` row) -- an UNVERIFIABLE
#       family (S7a/RFC §5.6's S7b tier: A6HF/ASOFT/M32LEHF/RV64 today) is
#       silently EXCLUDED, not a hard-fail. Each emitted row carries that
#       family's CI-boot representative (`verify`, an arch NAME string),
#       its rootfs pin (rootfs_target/rootfs_url/rootfs_sha256), and its
#       container_arch + build tuple (goarch/goarm/gomips/gomips64/go386),
#       so a caller (scripts/select-matrix.sh --verify-families) never
#       needs a second arches.json lookup to get the full row.
#
#       "Bootable representative" is an AUTHORED per-arch fact (round-2
#       D-SEV2 lives on, S7a sharpens it): each arch row carries its own
#       `verify` boolean, true on at most one row per family -- the one
#       arch string whose PINNED ROOTFS's OWN native /etc/apk/arch
#       genuinely reports that exact name (empirically confirmed per
#       family, not inferred). This is deliberately NOT "any row that
#       merely carries a rootfs pin, lexicographically-first": S7a found a
#       real case where that inference is wrong -- aarch64_cortex-a53 and
#       arm_cortex-a7 (the historical core arches) both still carry a
#       rootfs pin (needed by the ipk_arches-scoped legacy tests), but
#       their pinned rootfs's native /etc/apk/arch is aarch64_generic /
#       arm_cortex-a15_neon-vfpv4 respectively (a DIFFERENT arch string,
#       one hardfloat family over for the ARM case) -- so those two rows
#       carry `verify: false`, and the true representative is a sibling row
#       instead. Trusting "first with a rootfs pin" here would have silently
#       re-introduced the exact /etc/apk/arch-override mismatch bug S7a's
#       D2 removes from the verify path.
#
#       Hard-fails (schema violation, not a normal "unverified" case) if a
#       single family has MORE than one `verify: true` row, or if a
#       `verify: true` row does not itself carry a real rootfs pin.
#
#   families.sh --unverified-arches [arches.json]
#       S7b (RFC §5.6/§Slices S7b): the complement of --with-ci at arch
#       granularity. Emits, one per line, every FEASIBLE (`reason == null`)
#       arch NAME whose computed family has NO `verify: true` row anywhere
#       in the table -- i.e. every arch belonging to one of the S7b
#       "unverified" families (today: A6HF, ASOFT, M32LEHF, RV64). These
#       ship on architectural certainty alone: no bootable rootfs exists
#       whose native `/etc/apk/arch` confirms the family, so CI can never
#       qemu-verify them (unlike the 10 families --with-ci covers).
#       Excludes: every arch in a family --with-ci WOULD emit (boot-verified
#       families), and every infeasible arch (`reason != null` -- a
#       different tier entirely, never published at all). Reuses the exact
#       same per-arch row-building + family grouping `--with-ci` uses (see
#       `build_family_rows` below) -- this is a DERIVED view over the same
#       grouping, not a second, potentially-divergent way to compute
#       families. Publish-time consumer: scripts/publish-feed.sh's
#       `cmd_assemble` logs the intersection of this set with the run's
#       actually-published arches (S7b's named log() acceptance criterion).
#
#   families.sh --validate [arches.json]
#       The schema guard (round-2 P-SEV3): every row's build tuple must
#       map to a known family id (via --id-for; hard-fails on unmapped,
#       naming the offending arch), and goarch/float/endian/gomips/
#       gomips64/go386/tier must each be one of a fixed vocabulary. S7a
#       adds: `verify` must be boolean; a `verify: true` row must itself
#       carry a real rootfs pin (an authored mistake -- marking a
#       non-bootable row as the representative -- is a schema error, not a
#       silent no-op); and no family may have more than one `verify: true`
#       row. Prints one FAIL line per violation and exits non-zero if any
#       are found; otherwise prints a one-line OK summary and exits 0.
#
# POSIX sh only (mirrors scripts/select-matrix.sh's style/no-bashisms).
#
# Usage:
#   scripts/families.sh --id-for <goarch> <goarm> <gomips> <gomips64> <go386>
#   scripts/families.sh --with-ci [arches.json]
#   scripts/families.sh --unverified-arches [arches.json]
#   scripts/families.sh --validate [arches.json]

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)

usage() {
    cat >&2 <<'EOF'
Usage:
  families.sh --id-for <goarch> <goarm> <gomips> <gomips64> <go386>
  families.sh --with-ci [arches.json]
  families.sh --unverified-arches [arches.json]
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

# build_family_rows <arches.json> <out-file>
#
# Shared by --with-ci and --unverified-arches (S7b) so both derive families
# via the exact same per-arch grouping -- never a second, potentially-
# divergent way to compute them (deep-module discipline: one place knows how
# a row becomes a family-tagged JSONL record). Appends one JSONL row per
# FEASIBLE (`reason == null`) arch to <out-file>: family id, name, bootable
# (real rootfs pin present), verify_flag (this row's own `verify` boolean),
# rootfs fields, container_arch, and the build tuple. Infeasible rows
# (reason != null) are skipped entirely -- they have no family (the
# Appendix's own `family` column is blank for them). Hard-fails (schema
# violation, not a normal case) if any feasible row's build tuple is
# unmapped -- naming the offending arch and the calling command.
build_family_rows() {
    _arches_json="$1"; _out_file="$2"

    _count=$(jq 'length' "${_arches_json}")
    _i=0

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
            echo "families.sh: arch '${_name}' has an unmapped build tuple" >&2
            exit 1
        }

        _rootfs_target=$(echo "${_row}" | jq -r '.rootfs_target // ""')
        _rootfs_url=$(echo "${_row}" | jq -r '.rootfs_url // ""')
        _rootfs_sha256=$(echo "${_row}" | jq -r '.rootfs_sha256 // ""')
        _container_arch=$(echo "${_row}" | jq -r '.container_arch // ""')
        _verify=$(echo "${_row}" | jq -r '.verify // false')

        _bootable="false"
        if [ -n "${_rootfs_target}" ] && [ -n "${_rootfs_url}" ] && [ -n "${_rootfs_sha256}" ]; then
            _bootable="true"
        fi

        jq -n \
            --arg family "${_family}" \
            --arg name "${_name}" \
            --arg bootable "${_bootable}" \
            --arg verify "${_verify}" \
            --arg rootfs_target "${_rootfs_target}" \
            --arg rootfs_url "${_rootfs_url}" \
            --arg rootfs_sha256 "${_rootfs_sha256}" \
            --arg container_arch "${_container_arch}" \
            --arg goarch "${_goarch}" \
            --arg goarm "${_goarm}" \
            --arg gomips "${_gomips}" \
            --arg gomips64 "${_gomips64}" \
            --arg go386 "${_go386}" \
            '{family: $family, name: $name, bootable: ($bootable == "true"),
              verify_flag: ($verify == "true"),
              rootfs_target: $rootfs_target, rootfs_url: $rootfs_url, rootfs_sha256: $rootfs_sha256,
              container_arch: $container_arch,
              goarch: $goarch, goarm: $goarm, gomips: $gomips, gomips64: $gomips64, go386: $go386}' \
            >> "${_out_file}"
    done
}

cmd_with_ci() {
    _arches_json="${1:-${REPO_ROOT}/arches.json}"
    if [ ! -f "${_arches_json}" ]; then
        echo "families.sh: ${_arches_json} not found" >&2
        exit 1
    fi

    _rows_file=$(mktemp)
    trap 'rm -f "${_rows_file}"' EXIT
    build_family_rows "${_arches_json}" "${_rows_file}"

    # Group the per-arch rows by family. The verify representative is the
    # row an author explicitly marked `verify: true` (round-2 D-SEV2
    # sharpened by S7a -- see the header comment for why "any bootable
    # row, first by name" is the wrong inference). Hard-fail (schema
    # violation) if a family has MORE than one verify:true row, or if its
    # verify:true row is not itself bootable (an authored mistake). A
    # family with ZERO verify:true rows is not an error -- it is the S7b
    # "unverified" tier -- so it is simply excluded from this view's
    # output, not hard-failed.
    jq -s '
        group_by(.family)
        | map(
            . as $rows
            | ($rows[0].family) as $family
            | ([$rows[] | select(.verify_flag)]) as $marked
            | if ($marked | length) > 1
              then error("families.sh --with-ci: family " + $family + " has more than one verify:true arch (" + ([$marked[].name] | join(", ")) + ")")
              elif ($marked | length) == 0
              then empty
              else $marked[0] as $v
                | if ($v.bootable | not)
                  then error("families.sh --with-ci: family " + $family + "'"'"'s verify:true arch (" + $v.name + ") does not carry a real rootfs pin")
                  else {family: $family, verify: $v.name,
                        rootfs_target: $v.rootfs_target, rootfs_url: $v.rootfs_url, rootfs_sha256: $v.rootfs_sha256,
                        container_arch: $v.container_arch,
                        goarch: $v.goarch, goarm: $v.goarm, gomips: $v.gomips, gomips64: $v.gomips64, go386: $v.go386}
                  end
              end
          )
        | sort_by(.family)
    ' "${_rows_file}"
}

cmd_unverified_arches() {
    _arches_json="${1:-${REPO_ROOT}/arches.json}"
    if [ ! -f "${_arches_json}" ]; then
        echo "families.sh: ${_arches_json} not found" >&2
        exit 1
    fi

    _rows_file=$(mktemp)
    trap 'rm -f "${_rows_file}"' EXIT
    build_family_rows "${_arches_json}" "${_rows_file}"

    # S7b: the complement of --with-ci's own family grouping, at arch
    # granularity -- group the SAME per-arch rows by family, keep only the
    # families with ZERO verify:true rows (the unverified tier), then flatten
    # to just their arch names, one per line, sorted for a stable diff.
    # Deliberately does NOT duplicate --with-ci's ">1 verify:true" hard-fail
    # (that schema violation is families.sh --validate's job); this view only
    # cares whether a family has any verified representative at all.
    jq -s -r '
        group_by(.family)
        | map(select(([.[] | select(.verify_flag)] | length) == 0))
        | map(.[].name)
        | flatten
        | sort
        | .[]
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
    _verifyfamiliesfile=$(mktemp)
    trap 'rm -f "${_errfile}" "${_familiesfile}" "${_verifyfamiliesfile}"' EXIT

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
        _verify_type=$(echo "${_row}" | jq -r '.verify | type')
        _rootfs_target=$(echo "${_row}" | jq -r '.rootfs_target // ""')
        _rootfs_url=$(echo "${_row}" | jq -r '.rootfs_url // ""')
        _rootfs_sha256=$(echo "${_row}" | jq -r '.rootfs_sha256 // ""')

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

        # S7a: `verify` must be an authored boolean (not null/absent/a
        # string) -- a missing field would silently read as "not verify"
        # via --with-ci's `// false`, masking a forgotten field on a new
        # row. A `verify: true` row that lacks a real rootfs pin is an
        # authored contradiction (marking a non-bootable row as THE
        # bootable representative) -- caught here, not left to
        # --with-ci's own (looser, per-invocation) hard-fail.
        case "${_verify_type}" in
            boolean) ;;
            *)
                echo "FAIL: ${_name}: verify '${_verify_type}' is not a boolean" >&2
                _fail=1
                ;;
        esac

        if [ "${_verify_type}" = "boolean" ] && [ "$(echo "${_row}" | jq -r '.verify')" = "true" ]; then
            if [ -z "${_rootfs_target}" ] || [ -z "${_rootfs_url}" ] || [ -z "${_rootfs_sha256}" ]; then
                echo "FAIL: ${_name}: verify:true but missing a real rootfs pin (rootfs_target/rootfs_url/rootfs_sha256)" >&2
                _fail=1
            fi
        fi

        if [ "${_tier}" = "infeasible" ]; then
            : # no tuple to map -- infeasible rows have no family (Appendix)
        elif _family=$(id_for "${_goarch}" "${_goarm}" "${_gomips}" "${_gomips64}" "${_go386}" 2>"${_errfile}"); then
            echo "${_family}" >> "${_familiesfile}"
            if [ "${_verify_type}" = "boolean" ] && [ "$(echo "${_row}" | jq -r '.verify')" = "true" ]; then
                echo "${_family}" >> "${_verifyfamiliesfile}"
            fi
        else
            echo "FAIL: ${_name}: $(cat "${_errfile}")" >&2
            _fail=1
        fi
    done

    # S7a: at most one verify:true row per family -- two representatives
    # for the same family is the exact ambiguity --with-ci's own hard-fail
    # guards at read time; catching it here too gives a faster, more
    # specific diagnostic (names the family) during routine validation.
    if [ -s "${_verifyfamiliesfile}" ]; then
        _dup_families=$(sort "${_verifyfamiliesfile}" | uniq -d)
        if [ -n "${_dup_families}" ]; then
            for _dupfam in ${_dup_families}; do
                echo "FAIL: family ${_dupfam} has more than one verify:true row" >&2
            done
            _fail=1
        fi
    fi

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
    --unverified-arches)
        shift
        cmd_unverified_arches "${1:-}"
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
