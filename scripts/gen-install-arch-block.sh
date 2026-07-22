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

echo "# >>> GENERATED infeasible-arch block (scripts/gen-install-arch-block.sh) -- do not edit by hand"
echo "# Source: arches.json rows with reason != null (RFC docs/rfc-apk-arch-coverage.md"
echo "# section 5.5). Regenerate via scripts/gen-install-arch-block.sh; drift from"
echo "# arches.json is caught by tests/apk/install-arch-block.sh."
echo "infeasible_reason() {"
echo "    case \"\$1\" in"

jq -r '
    [.[] | select(.reason != null)]
    | sort_by(.name)
    | .[]
    | "\(.name)\t\(.reason)"
' "${ARCHES_JSON}" | while IFS="$(printf '\t')" read -r _giab_name _giab_reason; do
    printf '        %s)\n' "${_giab_name}"
    printf '            echo "%s"\n' "${_giab_reason}"
    printf '            ;;\n'
done

echo "        *)"
echo "            return 1"
echo "            ;;"
echo "    esac"
echo "}"
echo "# <<< END GENERATED infeasible-arch block"
