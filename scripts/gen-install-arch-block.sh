#!/bin/sh
# scripts/gen-install-arch-block.sh
#
# RFC docs/rfc-apk-arch-coverage.md section 5.5, slice S6: generates the
# infeasible-arch lookup that scripts/install.sh's apk_path() consults
# BEFORE ever touching the feed. arches.json's `reason` column (non-null
# means Go cannot target that arch at all) is the single source of truth;
# this generator is the one place that reads it, emitting a small,
# self-contained POSIX-sh function (infeasible_reason()) that gets spliced
# into scripts/install.sh between the BEGIN/END markers below. The shipped
# install.sh stays a single standalone fetched file with ZERO runtime
# dependency on arches.json/jq -- exactly as before this slice -- but there
# is only one authored source (arches.json) and one generation step,
# nothing left to hand-maintain or drift out of sync (section 5.2's own
# rule: no hand-authored duplicate + a drift-guard test; see
# tests/apk/install-arch-block.sh, which regenerates this block and asserts
# it is byte-identical to what's committed in scripts/install.sh).
#
# Rows are sorted by name (jq sort_by) before being emitted as case arms, so
# regenerating from an unchanged arches.json always produces byte-identical
# output -- the case-arm order never churns from row reordering elsewhere in
# arches.json.
#
# To regenerate scripts/install.sh's block by hand:
#   scripts/gen-install-arch-block.sh > /tmp/block.sh
#   then replace the text between the BEGIN/END markers in scripts/install.sh
#   with /tmp/block.sh's contents (tests/apk/install-arch-block.sh does this
#   comparison automatically -- this manual recipe is only for actually
#   updating the committed copy after an arches.json change).
#
# Usage:
#   scripts/gen-install-arch-block.sh [arches_json_path]
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
ARCHES_JSON="${1:-${REPO_ROOT}/arches.json}"

if [ ! -f "${ARCHES_JSON}" ]; then
    echo "gen-install-arch-block.sh: ${ARCHES_JSON} not found" >&2
    exit 1
fi

# escape_for_dq value -- M3 (code-review finding): `.reason` is free-form
# prose (not charclass-guarded like `.name` -- see scripts/arches.sh
# --validate's M1 check), and it gets spliced verbatim into a
# double-quoted `echo "..."` argument in the GENERATED block below. A
# reason containing `"` breaks OUT of that double-quoted string entirely
# (everything after becomes live shell text -- e.g. a reason of
# `x"; touch PWNED; echo "y` turns one echo call into three statements); a
# reason containing `$` or a backtick stays inside the quotes but still
# triggers command substitution. Escapes exactly the four characters POSIX
# double-quotes still treat specially (backslash, double-quote, dollar,
# backtick) so the emitted echo always prints the reason literally, no
# matter what it contains -- order matters: backslash MUST be escaped
# first, or a later pass would double-escape the backslashes it just
# inserted for the other three characters.
#
# Deliberately keeps the `echo "%s"` shape (rather than switching to
# `printf '%s\n' '...'` with single-quote wrapping) so this is a no-op for
# every reason in the CURRENT table (none contain these four characters) --
# the GENERATED block committed in scripts/install.sh stays byte-identical,
# no companion install.sh regeneration required by this fix. See
# tests/apk/install-arch-block.sh Part E for the injection-attempt
# regression proof.
escape_for_dq() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\$/\\$/g' -e 's/`/\\`/g'
}

# R2 (round-2 code-review finding, HIGH-adjacent companion to escape_for_dq
# above): the row loop below used to extract `.name`/`.reason` with
# `jq -r '"\(.name)\t\(.reason)"'` and split on tab. `-r` (raw output)
# DECODES JSON string escapes back to raw bytes -- so a `.reason`
# containing an embedded newline (a JSON-escaped `\n` inside the string)
# came out as an actual newline byte, splitting into what `while IFS=<tab>
# read` sees as an extra "row": everything after that embedded newline
# (potentially including a hand-crafted `) touch PWNED ;;`-shaped payload)
# spliced into the generated case statement as raw, un-escaped shell/case
# syntax rather than as literal text inside one row's `echo "..."` argument.
# arches.sh --validate now rejects any `.reason`/`.name` containing a
# newline or other control character at the source (R2a), but this
# generator does not rely on that alone: iterating with `jq -c` (compact,
# NOT `-r`) keeps every row's JSON string escaping intact, so an embedded
# control character can never manifest as a raw delimiter here -- each
# line read by the `while` loop below is always exactly one complete,
# still-escaped JSON object, whatever text its fields contain. The per-
# field values are then decoded (only) via a follow-up `jq -r` scoped to
# that single already-isolated object.
next_field() {
    # next_field <json-object> <field> -- decode one field of an already-
    # isolated single-line JSON object via a separate jq -r call (never via
    # raw-mode string interpolation across an object boundary).
    printf '%s' "$1" | jq -r --arg f "$2" '.[$f]'
}

echo "# >>> GENERATED infeasible-arch block (scripts/gen-install-arch-block.sh) -- do not edit by hand"
echo "# Source: arches.json rows with reason != null (RFC docs/rfc-apk-arch-coverage.md"
echo "# section 5.5). Regenerate via scripts/gen-install-arch-block.sh; drift from"
echo "# arches.json is caught by tests/apk/install-arch-block.sh."
echo "infeasible_reason() {"
echo "    case \"\$1\" in"

jq -c '
    [.[] | select(.reason != null)]
    | sort_by(.name)
    | .[]
' "${ARCHES_JSON}" | while IFS= read -r _giab_row; do
    _giab_name=$(next_field "${_giab_row}" name)
    _giab_reason=$(next_field "${_giab_row}" reason)
    _giab_escaped=$(escape_for_dq "${_giab_reason}")
    printf '        %s)\n' "${_giab_name}"
    printf '            echo "%s"\n' "${_giab_escaped}"
    printf '            ;;\n'
done

echo "        *)"
echo "            return 1"
echo "            ;;"
echo "    esac"
echo "}"
echo "# <<< END GENERATED infeasible-arch block"
