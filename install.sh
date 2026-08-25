#!/usr/bin/env bash
# Installs the status line and its hooks, then wires them into settings.json.
#
# Non-destructive by design:
#   - Files go to their own directory, so your existing hooks are untouched.
#   - settings.json is backed up before every write.
#   - Running it twice leaves exactly one copy of each hook entry.
#
# Usage:
#   ./install.sh [--prefix DIR] [--settings FILE] [--with-notifications]
#                [--dry-run] [--help]

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${HOME}/.claude/statusline"
SETTINGS="${HOME}/.claude/settings.json"
DRY_RUN=0
WITH_NOTIFICATIONS=0

usage() { sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)             PREFIX="$2"; shift 2 ;;
        --settings)           SETTINGS="$2"; shift 2 ;;
        --with-notifications) WITH_NOTIFICATIONS=1; shift ;;
        --dry-run)            DRY_RUN=1; shift ;;
        -h|--help)            usage ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

# --- Dependencies ---
if ! command -v jq >/dev/null 2>&1; then
    echo "error: jq is required. Install it with 'brew install jq' or 'apt install jq'." >&2
    exit 1
fi
command -v awk >/dev/null 2>&1 || { echo "error: awk is required." >&2; exit 1; }
command -v git >/dev/null 2>&1 || echo "warning: git not found. The branch segment will stay empty."

# --- Warn about an earlier hand-rolled install ---
if [ -f "$SETTINGS" ]; then
    legacy=$(jq -r --arg p "$PREFIX" '
        [ (.statusLine.command // empty) ]
        + [ (.hooks // {}) | to_entries[] | .value[]? | .hooks[]? | (.command // empty) ]
        | map(select(test("statusline-command\\.sh|session-name-check\\.sh|update-terminal-title\\.sh|record-activity\\.sh")))
        | map(select(contains($p) | not)) | unique | .[]
    ' "$SETTINGS" 2>/dev/null || true)
    if [ -n "$legacy" ]; then
        echo "warning: settings.json already references a status line outside $PREFIX:"
        printf '  %s\n' $legacy
        echo "         Those entries are left alone and may duplicate this install."
        echo "         Remove them by hand if you are replacing an older setup."
    fi
fi

sl_cmd="bash ${PREFIX}/statusline-command.sh"
ra_cmd="bash ${PREFIX}/hooks/record-activity.sh"
tt_cmd="bash ${PREFIX}/hooks/update-terminal-title.sh"
sn_cmd="bash ${PREFIX}/hooks/session-name-check.sh"
nt_cmd="bash ${PREFIX}/hooks/notify.sh"

# Build the merged settings. Existing entries that point into $PREFIX are
# stripped first, which is what makes a second run a no-op instead of a
# duplicate.
build_settings() {
    local base="{}"
    [ -f "$SETTINGS" ] && base=$(cat "$SETTINGS")
    printf '%s' "$base" | jq \
        --arg p "$PREFIX" --arg sl "$sl_cmd" --arg ra "$ra_cmd" \
        --arg tt "$tt_cmd" --arg sn "$sn_cmd" --arg nt "$nt_cmd" \
        --argjson notify "$WITH_NOTIFICATIONS" '
        def strip($p):
            map(.hooks |= map(select(((.command // "") | contains($p)) | not)))
            | map(select((.hooks | length) > 0));
        def add($ev; $entry):
            .[$ev] = (((.[$ev] // []) | strip($p)) + [$entry]);

        .statusLine = { type: "command", command: $sl }
        | .hooks = ((.hooks // {})
            | add("PostToolUse"; { hooks: [ { type: "command", command: $ra } ] })
            | add("Stop"; { hooks: (
                  [ { type: "command", command: $ra },
                    { type: "command", command: $tt } ]
                  + (if $notify == 1 then [ { type: "command", command: $nt } ] else [] end)
              ) })
            | add("UserPromptSubmit"; { hooks: [ { type: "command", command: $sn } ] })
            | (if $notify == 1
               then add("Notification"; { hooks: [ { type: "command", command: $nt } ] })
               else . end)
          )
    '
}

merged=$(build_settings)

if [ "$DRY_RUN" = "1" ]; then
    echo "--- would install to: $PREFIX"
    echo "--- would write:      $SETTINGS"
    printf '%s\n' "$merged"
    exit 0
fi

# --- Copy files ---
mkdir -p "${PREFIX}/lib" "${PREFIX}/hooks"
cp "${SRC}/statusline-command.sh" "${PREFIX}/statusline-command.sh"
cp "${SRC}/lib/paths.sh"          "${PREFIX}/lib/paths.sh"
cp "${SRC}"/hooks/*.sh            "${PREFIX}/hooks/"
chmod +x "${PREFIX}/statusline-command.sh" "${PREFIX}"/hooks/*.sh

# --- Write settings, backing up first ---
mkdir -p "$(dirname "$SETTINGS")"
if [ -f "$SETTINGS" ]; then
    backup="${SETTINGS}.bak-$(date '+%Y%m%d-%H%M%S')"
    cp "$SETTINGS" "$backup"
    echo "backed up settings to $backup"
fi

tmp="${SETTINGS}.tmp.$$"
printf '%s\n' "$merged" > "$tmp"
jq empty "$tmp" >/dev/null   # refuse to install invalid JSON
mv "$tmp" "$SETTINGS"

echo "installed to $PREFIX"
echo "wired into  $SETTINGS"
[ "$WITH_NOTIFICATIONS" = "1" ] && echo "desktop notifications: enabled"
echo
echo "Restart Claude Code, or start a new session, to see the status line."
