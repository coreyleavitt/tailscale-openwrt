#!/bin/sh
# scripts/arches.sh
#
# Slice S1a (RFC docs/rfc-apk-arch-coverage.md §5.2): "family" is a
# COMPUTED grouping key over each arch row's own build tuple
# (goarch/goarm/gomips/gomips64/go386), never an authored foreign key.
# This script is the single place that mnemonic table lives:
#
#   arches.sh --id-for <goarch> <goarm> <gomips> <gomips64> <go386>
#       Pure function: build tuple -> stable mnemonic family id (one of
#       the 14 in the RFC §4 table). Content-derived, insertion-order-
#       independent by construction (no positional/group_by ordering is
#       involved at all -- see round-2 D-SEV1/F-SEV3). Hard-fails (exit
#       1, stderr message, nothing on stdout) on a tuple that matches none
#       of the 14 known families -- a new family is a deliberate, reviewed
#       addition to the case statement below, never a silent generic id.
#
#   arches.sh --with-ci [arches.json]
#       Emits one JSON row per BOOTABLE family present in arches.json (a
#       family with at least one `native_verify: true` row) -- an
#       UNVERIFIABLE family (S7a/RFC §5.6's S7b tier: A6HF/ASOFT/M32LEHF/
#       RV64 today) is silently EXCLUDED, not a hard-fail. Each emitted row
#       carries that family's CI-boot representative under the OUTPUT key
#       `verify` (an arch NAME string -- this is select-matrix.sh's/
#       build-tailscale.yaml's `matrix.family.verify`, a DIFFERENT thing
#       from the per-row `native_verify` boolean this reads from; see M8
#       below), its rootfs pin (rootfs_target/rootfs_url/rootfs_sha256),
#       and its container_arch + build tuple (goarch/goarm/gomips/
#       gomips64/go386), so a caller (scripts/select-matrix.sh
#       --verify-families) never needs a second arches.json lookup to get
#       the full row.
#
#       "Bootable representative" is an AUTHORED per-arch fact (round-2
#       D-SEV2 lives on, S7a sharpens it, M8 renames the field): each arch
#       row carries its own `native_verify` boolean, true on at most one
#       row per family -- the one arch string whose PINNED ROOTFS's OWN
#       native /etc/apk/arch genuinely reports that exact name (empirically
#       confirmed per family, not inferred). This is deliberately NOT "any
#       row that merely carries a rootfs pin, lexicographically-first": S7a
#       found a real case where that inference is wrong -- aarch64_cortex-a53
#       and arm_cortex-a7 (the historical core arches) both still carry a
#       rootfs pin (needed by the ipk_arches-scoped legacy tests), but
#       their pinned rootfs's native /etc/apk/arch is aarch64_generic /
#       arm_cortex-a15_neon-vfpv4 respectively (a DIFFERENT arch string,
#       one hardfloat family over for the ARM case) -- so those two rows
#       carry `native_verify: false`, and the true representative is a
#       sibling row instead. Trusting "first with a rootfs pin" here would
#       have silently re-introduced the exact /etc/apk/arch-override
#       mismatch bug S7a's D2 removes from the verify path.
#
#       M8 (code-review finding, MEDIUM): the row field used to be named
#       `verify`, the exact same name as this command's own OUTPUT key
#       (the arch-name string consumed as `matrix.family.verify` by
#       select-matrix.sh/build-tailscale.yaml) -- two different concepts
#       (an authored per-row boolean vs. a derived per-family arch-name
#       string) sharing one name, with only prose (this comment) to tell a
#       reader which one a given `.verify` meant. Renaming the ROW field to
#       `native_verify` removes the conflation; the OUTPUT key stays
#       `verify` (an external contract -- see build-tailscale.yaml). It
#       also does NOT, on its own, tell a reader why a row can carry a real
#       rootfs pin (rootfs_target/rootfs_url/rootfs_sha256) while
#       `native_verify: false` (the aarch64_cortex-a53/arm_cortex-a7 case
#       above) -- that distinction is structural (rootfs_* = "has a pin",
#       native_verify = "IS the family's native-match representative") and
#       is now encoded, not just prose-explained, by --validate below: (1)
#       a `native_verify: true` row must carry a real rootfs pin, (2) at
#       most one `native_verify: true` row per family, and (3) a row MAY
#       carry a rootfs pin with `native_verify: false` -- legal, and
#       exactly the core-ARM case (tests/apk/arches.sh's M8 section
#       asserts --validate accepts this on the real table, not just that
#       the two failure modes are rejected).
#
#       Hard-fails (schema violation, not a normal "unverified" case) if a
#       single family has MORE than one `native_verify: true` row, or if a
#       `native_verify: true` row does not itself carry a real rootfs pin.
#
#   arches.sh --unverified-arches [arches.json]
#       S7b (RFC §5.6/§Slices S7b): the complement of --with-ci at arch
#       granularity. Emits, one per line, every FEASIBLE (`reason == null`)
#       arch NAME whose computed family has NO `native_verify: true` row
#       anywhere in the table -- i.e. every arch belonging to one of the S7b
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
#   arches.sh --tier-arches <tier> [arches.json]
#       M4 (code-review finding): the single accessor for "every arch name
#       whose own `tier` field equals <tier>", sorted for a stable diff.
#       Before this existed, `select(.tier == "core") | .name` was hand-
#       authored independently in FOUR places (tailscale-package/
#       build-apk.sh, scripts/publish-feed.sh's committed-core depublish
#       guard, .github/workflows/build-tailscale.yaml's two republish-feed
#       loops) -- a future redefinition of "core" needed four synchronized
#       edits, with nothing to catch a missed one. All four now route
#       through this accessor (tests/apk/arches.sh's M4 section
#       grep-guards that no authored `select(.tier == "core")` string
#       remains at any of those sites). Hard-fails on an unknown <tier>
#       (not one of core|extended|infeasible) rather than silently
#       returning an empty set.
#
#   arches.sh --resolve-republish-arches <allowlist> [arches.json]
#       RFC §5.8 "Rollback" (round-2 B-SEV2): the resolve+validate seam for
#       `republish-feed`'s optional `republish_arches` workflow_dispatch
#       input (a raw, operator-typed string) -- kept here, not a separate
#       script, so it can call cmd_tier_arches directly, in-process,
#       rather than re-shelling out to this same file (the same locality
#       --with-ci/--unverified-arches/--compile-families already get by
#       sharing build_family_rows()).
#
#         ""/whitespace/commas only -> the tier=="core" set, UNCHANGED --
#             an existing core republish/rollback must behave exactly as
#             before this input existed (behavior-preserving default).
#         non-empty -> a comma- and/or space-separated list of arch names,
#             split, each checked against the FEASIBLE set (tier core
#             UNION tier extended -- reuses --tier-arches TWICE rather
#             than a third, independently-authored `reason == null` jq
#             literal). Emits EXACTLY the listed names, de-duplicated and
#             sorted -- never a superset, never silently fewer.
#
#       Hard-fails (exit 1, stderr message naming the offending token,
#       NOTHING on stdout -- a mixed valid+invalid allowlist fails whole,
#       never partially) on:
#         - a token that is not a real arch name in arches.json at all
#           (unknown/typo), or
#         - a token that names a real arch whose own tier is "infeasible"
#           (e.g. powerpc_8548 -- reason != null, Go cannot build it, never
#           a republish target), or
#         - a token that doesn't match the safe arch-name charclass
#           `^[a-z0-9][a-z0-9_.-]*$` arches.sh --validate already
#           enforces on every real row's `.name` (M1) -- checked
#           explicitly here too, BEFORE the membership check, since this
#           command's own stdout is what build-tailscale.yaml's
#           republish-feed assemble/verify loops splice into a shell `for
#           arch in ...` -- the exact injection surface M1 closed for
#           arches.json's own `.name` field. (In practice the membership
#           check alone would also reject any injection-shaped token --
#           it can never equal a real feasible name, since --validate
#           already forbids that shape on every row -- but the explicit
#           shape check gives a precise, fast diagnostic instead of a
#           generic "not feasible".)
#
#   arches.sh --compile-families [arches.json]
#       M5 (code-review finding): given an arches.json-shaped array (the
#       CALLER'S job to have already gated -- e.g.
#       scripts/select-matrix.sh --compile-families gates to `reason ==
#       null` non-PR / a single canary row on PR, same as it always has),
#       group the FEASIBLE rows by family and emit one row per family:
#       the build tuple + that family's gated arch names, sorted. Built on
#       the exact same `build_family_rows` grouping --with-ci/
#       --unverified-arches already share -- never a second,
#       independently-maintained "iterate rows -> --id-for per row ->
#       group_by" loop (which is what select-matrix.sh --compile-families
#       used to do, invoking --id-for as a subprocess per row instead of
#       delegating wholesale the way --verify-families already delegates
#       to --with-ci).
#
#   arches.sh --validate [arches.json]
#       The schema guard (round-2 P-SEV3): every row's build tuple must
#       map to a known family id (via --id-for; hard-fails on unmapped,
#       naming the offending arch), and goarch/float/endian/gomips/
#       gomips64/go386/tier must each be one of a fixed vocabulary. S7a
#       adds: `native_verify` (M8: renamed from `verify` -- see --with-ci's
#       header comment for why) must be boolean; a `native_verify: true`
#       row must itself carry a real rootfs pin (an authored mistake --
#       marking a non-bootable row as the representative -- is a schema
#       error, not a silent no-op); and no family may have more than one
#       `native_verify: true` row. A row carrying a real rootfs pin with
#       `native_verify: false` is explicitly LEGAL and not checked for here
#       (the core-ARM install-verify-only case) -- rootfs_* means "has a
#       pin", native_verify means "IS the native-match representative",
#       and this schema guard only ever constrains the latter. Prints one
#       FAIL line per violation and exits non-zero if any are found;
#       otherwise prints a one-line OK summary and exits 0.
#
#       R1 (round-2 code-review finding, MEDIUM): TWO feasibility
#       predicates exist across the consumers of this table --
#       `.reason == null` (build_family_rows/select-matrix's gate) and
#       `.tier != "infeasible"` (--tier-arches/--resolve-republish-arches).
#       They happen to agree on every row today, but nothing enforced that
#       agreement AT THE SCHEMA LEVEL -- a future edit could set
#       `tier: "extended"` while forgetting to null out `reason` (or vice
#       versa) and --validate would have said nothing, while the two
#       predicates silently diverged for every other consumer. This is now
#       a hard schema invariant: `(.tier == "infeasible") == (.reason !=
#       null)` -- an infeasible row MUST carry a non-null reason, and a
#       feasible (core/extended) row MUST carry a null reason. Violations
#       name the offending row.
#
#       R2a (round-2 code-review finding, MEDIUM, companion to
#       gen-install-arch-block.sh's escape_for_dq fix): `.reason` is
#       human-authored prose that gets spliced, one row per line, into
#       scripts/install.sh's GENERATED infeasible-arch block (see that
#       generator's own header comment). A `.reason` (or, defensively,
#       a `.name` -- already charclass-guarded above, but a charclass
#       `grep -Eq` match is evaluated PER LINE, so an embedded newline
#       could in principle let one matching line mask other, unchecked
#       lines) containing a literal newline, carriage return, or other
#       control character breaks that one-row-per-line assumption and is
#       rejected here, at the source of truth, rather than relying solely
#       on the generator's own defenses.
#
# POSIX sh only (mirrors scripts/select-matrix.sh's style/no-bashisms).
#
# Usage:
#   scripts/arches.sh --id-for <goarch> <goarm> <gomips> <gomips64> <go386>
#   scripts/arches.sh --with-ci [arches.json]
#   scripts/arches.sh --unverified-arches [arches.json]
#   scripts/arches.sh --tier-arches <tier> [arches.json]
#   scripts/arches.sh --resolve-republish-arches <allowlist> [arches.json]
#   scripts/arches.sh --compile-families [arches.json]
#   scripts/arches.sh --validate [arches.json]

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)

usage() {
    cat >&2 <<'EOF'
Usage:
  arches.sh --id-for <goarch> <goarm> <gomips> <gomips64> <go386>
  arches.sh --with-ci [arches.json]
  arches.sh --unverified-arches [arches.json]
  arches.sh --tier-arches <tier> [arches.json]
  arches.sh --resolve-republish-arches <allowlist> [arches.json]
  arches.sh --compile-families [arches.json]
  arches.sh --validate [arches.json]
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
            echo "arches.sh: unmapped build tuple (goarch='${_goarch}' goarm='${_goarm}' gomips='${_gomips}' gomips64='${_gomips64}' go386='${_go386}') -- not one of the 14 known families" >&2
            return 1
            ;;
    esac
}

cmd_id_for() {
    [ $# -eq 5 ] || { usage; exit 1; }
    id_for "$1" "$2" "$3" "$4" "$5"
}

# extract_tuple <row-json>
#
# Sets _goarch/_goarm/_gomips/_gomips64/_go386 from a single row's JSON.
# The 5-field build-tuple list (goarch/goarm/gomips/gomips64/go386, each
# `// ""` so an absent field reads as the empty string id_for expects) is
# extracted independently by build_family_rows and cmd_validate; this is the
# one place that field list lives, so the two call sites can never drift
# apart on it.
extract_tuple() {
    _tuple_row="$1"

    _goarch=$(echo "${_tuple_row}" | jq -r '.goarch // ""')
    _goarm=$(echo "${_tuple_row}" | jq -r '.goarm // ""')
    _gomips=$(echo "${_tuple_row}" | jq -r '.gomips // ""')
    _gomips64=$(echo "${_tuple_row}" | jq -r '.gomips64 // ""')
    _go386=$(echo "${_tuple_row}" | jq -r '.go386 // ""')
}

# build_family_rows <arches.json> <out-file>
#
# Shared by --with-ci and --unverified-arches (S7b) so both derive families
# via the exact same per-arch grouping -- never a second, potentially-
# divergent way to compute them (deep-module discipline: one place knows how
# a row becomes a family-tagged JSONL record). Appends one JSONL row per
# FEASIBLE (`reason == null`) arch to <out-file>: family id, name, bootable
# (real rootfs pin present), native_verify_flag (this row's own
# `native_verify` boolean, M8: renamed from `verify` -- distinct from
# --with-ci's own OUTPUT key `verify`, an arch-name string; see that
# command's header comment), rootfs fields, container_arch, and the build
# tuple. Infeasible rows
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

        extract_tuple "${_row}"

        _family=$(id_for "${_goarch}" "${_goarm}" "${_gomips}" "${_gomips64}" "${_go386}") || {
            echo "arches.sh: arch '${_name}' has an unmapped build tuple" >&2
            exit 1
        }

        _rootfs_target=$(echo "${_row}" | jq -r '.rootfs_target // ""')
        _rootfs_url=$(echo "${_row}" | jq -r '.rootfs_url // ""')
        _rootfs_sha256=$(echo "${_row}" | jq -r '.rootfs_sha256 // ""')
        _container_arch=$(echo "${_row}" | jq -r '.container_arch // ""')
        _native_verify=$(echo "${_row}" | jq -r '.native_verify // false')

        _bootable="false"
        if [ -n "${_rootfs_target}" ] && [ -n "${_rootfs_url}" ] && [ -n "${_rootfs_sha256}" ]; then
            _bootable="true"
        fi

        jq -n \
            --arg family "${_family}" \
            --arg name "${_name}" \
            --arg bootable "${_bootable}" \
            --arg native_verify "${_native_verify}" \
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
              native_verify_flag: ($native_verify == "true"),
              rootfs_target: $rootfs_target, rootfs_url: $rootfs_url, rootfs_sha256: $rootfs_sha256,
              container_arch: $container_arch,
              goarch: $goarch, goarm: $goarm, gomips: $gomips, gomips64: $gomips64, go386: $go386}' \
            >> "${_out_file}"
    done
}

cmd_with_ci() {
    _arches_json="${1:-${REPO_ROOT}/arches.json}"
    if [ ! -f "${_arches_json}" ]; then
        echo "arches.sh: ${_arches_json} not found" >&2
        exit 1
    fi

    _rows_file=$(mktemp)
    trap 'rm -f "${_rows_file}"' EXIT
    build_family_rows "${_arches_json}" "${_rows_file}"

    # Group the per-arch rows by family. The verify representative is the
    # row an author explicitly marked `native_verify: true` (round-2
    # D-SEV2 sharpened by S7a, field renamed by M8 -- see the header
    # comment for why "any bootable row, first by name" is the wrong
    # inference, and why `native_verify` != this command's own OUTPUT key
    # `verify` below). Hard-fail (schema violation) if a family has MORE
    # than one native_verify:true row, or if its native_verify:true row is
    # not itself bootable (an authored mistake). A family with ZERO
    # native_verify:true rows is not an error -- it is the S7b
    # "unverified" tier -- so it is simply excluded from this view's
    # output, not hard-failed.
    jq -s '
        group_by(.family)
        | map(
            . as $rows
            | ($rows[0].family) as $family
            | ([$rows[] | select(.native_verify_flag)]) as $marked
            | if ($marked | length) > 1
              then error("arches.sh --with-ci: family " + $family + " has more than one native_verify:true arch (" + ([$marked[].name] | join(", ")) + ")")
              elif ($marked | length) == 0
              then empty
              else $marked[0] as $v
                | if ($v.bootable | not)
                  then error("arches.sh --with-ci: family " + $family + "'"'"'s native_verify:true arch (" + $v.name + ") does not carry a real rootfs pin")
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
        echo "arches.sh: ${_arches_json} not found" >&2
        exit 1
    fi

    _rows_file=$(mktemp)
    trap 'rm -f "${_rows_file}"' EXIT
    build_family_rows "${_arches_json}" "${_rows_file}"

    # S7b: the complement of --with-ci's own family grouping, at arch
    # granularity -- group the SAME per-arch rows by family, keep only the
    # families with ZERO native_verify:true rows (the unverified tier), then
    # flatten to just their arch names, one per line, sorted for a stable
    # diff. Deliberately does NOT duplicate --with-ci's ">1 native_verify:true"
    # hard-fail (that schema violation is arches.sh --validate's job); this
    # view only cares whether a family has any verified representative at all.
    jq -s -r '
        group_by(.family)
        | map(select(([.[] | select(.native_verify_flag)] | length) == 0))
        | map(.[].name)
        | flatten
        | sort
        | .[]
    ' "${_rows_file}"
}

cmd_tier_arches() {
    _tier="$1"
    _arches_json="${2:-${REPO_ROOT}/arches.json}"

    case "${_tier}" in
        core|extended|infeasible) ;;
        *)
            echo "arches.sh --tier-arches: '${_tier}' is not a known tier (core|extended|infeasible)" >&2
            exit 1
            ;;
    esac

    if [ ! -f "${_arches_json}" ]; then
        echo "arches.sh: ${_arches_json} not found" >&2
        exit 1
    fi

    jq -r --arg tier "${_tier}" '[.[] | select(.tier == $tier) | .name] | sort | .[]' "${_arches_json}"
}

# cmd_resolve_republish_arches <allowlist> <arches.json>
#
# RFC §5.8 "Rollback" (round-2 B-SEV2): see this command's header comment
# above for the full contract. Delegates the empty-default and the
# feasible-membership check to cmd_tier_arches (in-process call, not a
# subprocess) -- never a second, independently-authored "which arches are
# core/extended" predicate.
cmd_resolve_republish_arches() {
    _allowlist="${1-}"
    _resolve_arches_json="${2:-${REPO_ROOT}/arches.json}"

    if [ ! -f "${_resolve_arches_json}" ]; then
        echo "arches.sh: ${_resolve_arches_json} not found" >&2
        exit 1
    fi

    # Accept comma- and/or space-separated input (a workflow_dispatch text
    # input is natural typed either way) by collapsing commas to spaces
    # before the `for` word-split below treats both separators identically.
    _tokens=$(printf '%s' "${_allowlist}" | tr ',' ' ')

    # Empty, or whitespace/commas only -> the tier=="core" set, UNCHANGED
    # (behavior-preserving default -- an existing core republish/rollback
    # must work exactly as before this input existed).
    if [ -z "$(printf '%s' "${_tokens}" | tr -d '[:space:]')" ]; then
        cmd_tier_arches core "${_resolve_arches_json}"
        return 0
    fi

    _core=$(cmd_tier_arches core "${_resolve_arches_json}")
    _extended=$(cmd_tier_arches extended "${_resolve_arches_json}")

    _feasible_file=$(mktemp)
    _resolved_file=$(mktemp)
    trap 'rm -f "${_feasible_file}" "${_resolved_file}"' EXIT

    printf '%s\n%s\n' "${_core}" "${_extended}" | sed '/^$/d' | sort -u > "${_feasible_file}"

    for _tok in ${_tokens}; do
        # M1-equivalent shape guard, checked BEFORE membership: this
        # command's stdout is spliced into a shell `for arch in ...` in
        # build-tailscale.yaml's republish-feed loops, the exact same
        # injection surface arches.sh --validate's M1 section closes for
        # arches.json's own `.name` field. A shape violation can never
        # equal a real feasible name anyway (every real name already
        # passes this same charclass, per --validate), but checking it
        # explicitly gives a precise diagnostic instead of a generic "not
        # feasible" for an obviously-malicious token.
        if ! printf '%s' "${_tok}" | grep -Eq '^[a-z0-9][a-z0-9_.-]*$'; then
            echo "arches.sh --resolve-republish-arches: '${_tok}' does not match the safe arch-name shape ^[a-z0-9][a-z0-9_.-]*\$ -- refusing (this name is echoed verbatim into a shell loop downstream, e.g. build-tailscale.yaml's republish-feed loops)" >&2
            exit 1
        fi

        if ! grep -Fxq -- "${_tok}" "${_feasible_file}"; then
            echo "arches.sh --resolve-republish-arches: '${_tok}' is not a known FEASIBLE arch (tier core or extended) in ${_resolve_arches_json} -- refusing to republish an unknown or infeasible-tier arch name" >&2
            exit 1
        fi

        echo "${_tok}" >> "${_resolved_file}"
    done

    sort -u "${_resolved_file}"
}

# cmd_compile_families <arches.json>
#
# M5: group an (already-gated, caller's responsibility) arches.json-shaped
# array by family via the SAME build_family_rows() every other multi-arch
# view (--with-ci/--unverified-arches) shares -- never a second grouping
# loop. Infeasible rows (reason != null) are excluded by build_family_rows
# itself, same as everywhere else it's used.
cmd_compile_families() {
    _arches_json="${1:-${REPO_ROOT}/arches.json}"
    if [ ! -f "${_arches_json}" ]; then
        echo "arches.sh: ${_arches_json} not found" >&2
        exit 1
    fi

    _rows_file=$(mktemp)
    trap 'rm -f "${_rows_file}"' EXIT
    build_family_rows "${_arches_json}" "${_rows_file}"

    # Group by family (content-derived, not insertion/row-order -- every row
    # in a family carries an identical build tuple by construction, so
    # `.[0]`'s tuple fields are the family's tuple). `arches` is sorted so
    # the output is independent of the input's row order.
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
    ' "${_rows_file}"
}

# reject_ctrl_or_nl <value> <newline-fail-msg> <ctrl-fail-msg>
#
# R2a: shared embedded-newline / other-control-character rejection, used by
# cmd_validate for both `.name` and `.reason`. A `grep -Eq` line-anchored
# charclass match (the name-shape check above it) is satisfied if ANY line
# of a multi-line value matches, so a crafted value could otherwise slip a
# control-character-laden remainder past a single-line check undetected;
# this is the defense-in-depth check that catches that directly. Prints
# <newline-fail-msg> to stderr (prefixed "FAIL: ") and returns 1 if <value>
# contains an embedded newline; prints <ctrl-fail-msg> (same prefix) and
# returns 1 if it contains any other control character; otherwise returns 0
# and prints nothing. Callers own their own exact message text (so each
# field's diagnostic wording is unchanged) and their own `_fail=1`
# bookkeeping.
reject_ctrl_or_nl() {
    _rcn_value="$1"; _rcn_newline_msg="$2"; _rcn_ctrl_msg="$3"

    _rcn_newlines=$(printf '%s' "${_rcn_value}" | wc -l | tr -d ' ')
    if [ "${_rcn_newlines}" != "0" ]; then
        echo "FAIL: ${_rcn_newline_msg}" >&2
        return 1
    elif printf '%s' "${_rcn_value}" | LC_ALL=C grep -q '[[:cntrl:]]'; then
        echo "FAIL: ${_rcn_ctrl_msg}" >&2
        return 1
    fi
    return 0
}

cmd_validate() {
    _arches_json="${1:-${REPO_ROOT}/arches.json}"
    if [ ! -f "${_arches_json}" ]; then
        echo "arches.sh: ${_arches_json} not found" >&2
        exit 1
    fi

    _fail=0
    _count=$(jq 'length' "${_arches_json}")
    _i=0
    _errfile=$(mktemp)
    _familiesfile=$(mktemp)
    _nativeverifyfamiliesfile=$(mktemp)
    trap 'rm -f "${_errfile}" "${_familiesfile}" "${_nativeverifyfamiliesfile}"' EXIT

    while [ "${_i}" -lt "${_count}" ]; do
        _row=$(jq -c ".[${_i}]" "${_arches_json}")
        _idx="${_i}"
        _i=$((_i + 1))

        _raw_name=$(echo "${_row}" | jq -r '.name // empty')
        _name="${_raw_name}"
        if [ -z "${_name}" ]; then
            _name="<row ${_idx}>"
        fi

        # M1 (code-review finding): `.name` flows verbatim into shell text
        # downstream (e.g. publish-feed.sh's `xargs -I{} sh -c '... arch="{}"
        # ...'` textual splice) -- a name containing shell metacharacters
        # (space, quote, `;`, `$`, backtick, `/`, ...) is a command-injection
        # vector at that splice site. The root fix lives here, at the schema
        # guard: hard-fail any row whose name doesn't match the same safe
        # arch-name charclass scripts/detect-arch-drift.sh already uses to
        # filter the live OpenWrt index (`^[a-z0-9][a-z0-9_.-]*$`) -- POSIX
        # `case` glob brackets don't enforce a full-string charclass (the
        # trailing `*` matches ANY characters, not just the bracketed set),
        # so this needs real regex matching, not a case pattern.
        if ! printf '%s' "${_raw_name}" | grep -Eq '^[a-z0-9][a-z0-9_.-]*$'; then
            echo "FAIL: ${_name}: name '${_raw_name}' does not match the safe arch-name shape ^[a-z0-9][a-z0-9_.-]*\$ (used verbatim in shell text downstream, e.g. publish-feed.sh's xargs splice)" >&2
            _fail=1
        fi

        # R2a: defense-in-depth against a multi-line `.name` (the charclass
        # check above is a `grep -Eq` line-anchored match -- it is satisfied
        # if ANY line of a multi-line value matches, so a crafted name whose
        # first line is innocuous could otherwise slip a control-character-
        # laden remainder past it undetected).
        if ! reject_ctrl_or_nl "${_raw_name}" \
            "${_name}: name '${_raw_name}' contains an embedded newline -- must be a single line" \
            "${_name}: name '${_raw_name}' contains a control character -- must be a single clean printable-ASCII token"
        then
            _fail=1
        fi

        # R2a: `.reason` is free-form prose spliced one-row-per-line into
        # scripts/gen-install-arch-block.sh's GENERATED case statement (see
        # that generator's own header comment) -- a reason is required to be
        # a single clean printable line; an embedded newline/CR/other
        # control character is rejected here, at the schema, rather than
        # relied on the generator alone to defend against.
        _raw_reason=$(echo "${_row}" | jq -r '.reason // empty')
        if [ -n "${_raw_reason}" ]; then
            if ! reject_ctrl_or_nl "${_raw_reason}" \
                "${_name}: reason contains an embedded newline -- must be a single printable line" \
                "${_name}: reason contains a control character -- must be a single clean printable-ASCII line"
            then
                _fail=1
            fi
        fi

        extract_tuple "${_row}"
        _endian=$(echo "${_row}" | jq -r '.endian // ""')
        _float=$(echo "${_row}" | jq -r '.float // ""')
        _tier=$(echo "${_row}" | jq -r '.tier // ""')
        _native_verify_type=$(echo "${_row}" | jq -r '.native_verify | type')
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
            # GOARCH_VOCAB_CANONICAL (M6 code-review finding drift-guard
            # anchor): this exact vocabulary is ALSO hard-fail-guarded,
            # independently, inside tailscale-package/Dockerfile's build
            # stage (it runs in-container, with no access to this script --
            # see that file's own matching GOARCH_VOCAB_CANONICAL marker
            # comment). tests/apk/dockerfile-goarch-drift.sh greps the line
            # immediately below EACH marker in both files and asserts the
            # two pipe-delimited vocabularies are set-equal -- so a GOARCH
            # added here and forgotten there (or vice versa) fails CI
            # instead of silently diverging.
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

        # R1: the feasibility-duality invariant -- `.tier == "infeasible"`
        # (build_family_rows'/select-matrix's own gate) and `.reason != null`
        # (--tier-arches'/--resolve-republish-arches' notion of "not
        # feasible") must always agree, or those two consumer families
        # silently diverge on a future arches.json edit that sets one field
        # but forgets its counterpart. Checked via jq's own `== null`
        # (type-aware), not a truthiness/emptiness test -- an authored
        # `reason: ""` (non-null, but empty) must still count as "has a
        # reason" for this invariant.
        _reason_is_null=$(echo "${_row}" | jq -r '.reason == null')
        if [ "${_tier}" = "infeasible" ] && [ "${_reason_is_null}" = "true" ]; then
            echo "FAIL: ${_name}: tier is 'infeasible' but reason is null -- every infeasible row must carry a non-null reason (R1: tier/reason duality)" >&2
            _fail=1
        elif [ "${_tier}" != "infeasible" ] && [ "${_reason_is_null}" = "false" ]; then
            echo "FAIL: ${_name}: tier is '${_tier}' but reason is non-null -- every feasible (core/extended) row must carry a null reason (R1: tier/reason duality)" >&2
            _fail=1
        fi

        # S7a: `native_verify` (M8: renamed from `verify` -- this is the
        # ROW field, a DIFFERENT thing from --with-ci's own OUTPUT key
        # `verify`, an arch-name string; see --with-ci's header comment)
        # must be an authored boolean (not null/absent/a string) -- a
        # missing field would silently read as "not the native-verify
        # representative" via --with-ci's `// false`, masking a forgotten
        # field on a new row. A `native_verify: true` row that lacks a real
        # rootfs pin is an authored contradiction (marking a non-bootable
        # row as THE bootable representative) -- caught here, not left to
        # --with-ci's own (looser, per-invocation) hard-fail. The converse
        # -- a row that carries a real rootfs pin with `native_verify:
        # false` -- is explicitly NOT checked here: it is legal (the
        # core-ARM install-verify-only case, M8), because rootfs_* means
        # "has a pin" and native_verify means "IS the native-match
        # representative" -- two independent facts, not one inferred from
        # the other.
        case "${_native_verify_type}" in
            boolean) ;;
            *)
                echo "FAIL: ${_name}: native_verify '${_native_verify_type}' is not a boolean" >&2
                _fail=1
                ;;
        esac

        if [ "${_native_verify_type}" = "boolean" ] && [ "$(echo "${_row}" | jq -r '.native_verify')" = "true" ]; then
            if [ -z "${_rootfs_target}" ] || [ -z "${_rootfs_url}" ] || [ -z "${_rootfs_sha256}" ]; then
                echo "FAIL: ${_name}: native_verify:true but missing a real rootfs pin (rootfs_target/rootfs_url/rootfs_sha256)" >&2
                _fail=1
            fi
        fi

        if [ "${_tier}" = "infeasible" ]; then
            : # no tuple to map -- infeasible rows have no family (Appendix)
        elif _family=$(id_for "${_goarch}" "${_goarm}" "${_gomips}" "${_gomips64}" "${_go386}" 2>"${_errfile}"); then
            echo "${_family}" >> "${_familiesfile}"
            if [ "${_native_verify_type}" = "boolean" ] && [ "$(echo "${_row}" | jq -r '.native_verify')" = "true" ]; then
                echo "${_family}" >> "${_nativeverifyfamiliesfile}"
            fi
        else
            echo "FAIL: ${_name}: $(cat "${_errfile}")" >&2
            _fail=1
        fi
    done

    # S7a: at most one native_verify:true row per family -- two
    # representatives for the same family is the exact ambiguity
    # --with-ci's own hard-fail guards at read time; catching it here too
    # gives a faster, more specific diagnostic (names the family) during
    # routine validation. Together with the per-row check above (a
    # native_verify:true row must carry a real rootfs pin), this is the
    # FULL M8 invariant: at most one native-match representative per
    # family, always bootable when marked -- encoded here, not left to
    # this comment's prose alone.
    if [ -s "${_nativeverifyfamiliesfile}" ]; then
        _dup_families=$(sort "${_nativeverifyfamiliesfile}" | uniq -d)
        if [ -n "${_dup_families}" ]; then
            for _dupfam in ${_dup_families}; do
                echo "FAIL: family ${_dupfam} has more than one native_verify:true row" >&2
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
        echo "arches.sh --validate: FAILED" >&2
        exit 1
    fi
    echo "arches.sh --validate: OK (${_count} row(s), ${_family_count} families, all tuples mapped, all enums valid)"
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
    --tier-arches)
        shift
        [ $# -ge 1 ] || { usage; exit 1; }
        cmd_tier_arches "$1" "${2:-}"
        ;;
    --resolve-republish-arches)
        shift
        cmd_resolve_republish_arches "${1:-}" "${2:-}"
        ;;
    --compile-families)
        shift
        cmd_compile_families "${1:-}"
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
