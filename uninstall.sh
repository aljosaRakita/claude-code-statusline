#!/usr/bin/env bash
# Removes the status line and its hooks from settings.json, then deletes the
# installed files. Only entries pointing into the install prefix are touched.
#
# Usage:
#   ./uninstall.sh [--prefix DIR] [--settings FILE] [--keep-files] [--dry-run]

set -euo pipefail

PREFIX="${HOME}/.claude/statusline"
SETTINGS="${HOME}/.claude/settings.json"
KEEP_FILES=0
DRY_RUN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)     PREFIX="$2"; shift 2 ;;
        --settings)   SETTINGS="$2"; shift 2 ;;
        --keep-files) KEEP_FILES=1; shift ;;
        --dry-run)    DRY_RUN=1; shift ;;
        -h|--help)    sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

command -v jq >/dev/null 2>&1 || { echo "error: jq is required." >&2; exit 1; }

case "$PREFIX" in
    "$HOME"/*) PREFIX_CMD="~${PREFIX#"$HOME"}" ;;
    *)         PREFIX_CMD="$PREFIX" ;;
esac

if [ -f "$SETTINGS" ]; then
    cleaned=$(jq --arg p "$PREFIX" --arg pc "$PREFIX_CMD" '
        # Every hook command that points under the prefix directory is treated
        # as owned by the installer, because the prefix is the package directory
        # (default ~/.claude/statusline/). A foreign hook that merely references
        # a path under it is stripped too. To keep such a hook, install with a
        # dedicated --prefix so the two directories no longer overlap.
        def strip:
            map(if (.hooks | type) == "array" then .hooks |= map(select(
                (((.command // "") | contains($p + "/")) or ((.command // "") | contains($pc + "/"))) | not
            )) else . end)
            | map(select((.hooks | type) != "array" or (.hooks | length) > 0));

        (if (((.statusLine.command // "") | contains($p + "/"))
             or ((.statusLine.command // "") | contains($pc + "/")))
         then del(.statusLine) else . end)
        | (if .hooks then .hooks |= with_entries(if (.value | type) == "array" then .value |= strip else . end) else . end)
        | (if .hooks then .hooks |= with_entries(select((.value | type) != "array" or (.value | length) > 0)) else . end)
    ' "$SETTINGS")

    if [ "$DRY_RUN" = "1" ]; then
        echo "--- would write: $SETTINGS"
        printf '%s\n' "$cleaned"
    else
        backup="${SETTINGS}.bak-$(date '+%Y%m%d-%H%M%S')"
        cp "$SETTINGS" "$backup"
        tmp="${SETTINGS}.tmp.$$"
        printf '%s\n' "$cleaned" > "$tmp"
        jq empty "$tmp" >/dev/null
        mv "$tmp" "$SETTINGS"
        echo "backed up settings to $backup"
        echo "removed status line entries from $SETTINGS"
    fi
fi

if [ "$DRY_RUN" = "1" ]; then
    echo "--- would remove: $PREFIX"
elif [ "$KEEP_FILES" = "0" ] && [ -d "$PREFIX" ]; then
    rm -rf "$PREFIX"
    echo "removed $PREFIX"
fi

echo
echo "State files in the state directory are left in place. Remove them with:"
echo "  rm -f \"\$(bash -c '. ${PREFIX}/lib/paths.sh 2>/dev/null; cc_state_dir')\"/claude-session-*.name"
