#!/usr/bin/env bash
# Desktop notification for Claude Code events. Wire it to Notification and Stop.
#
#   macOS  -> terminal-notifier when installed, otherwise osascript.
#   Linux  -> notify-send when installed.
#   other  -> silent success. A missing notifier must never fail a hook.
#
# CC_NOTIFY_SENDER borrows another app's icon on macOS and focuses that app when
# the notification is clicked, for example com.microsoft.VSCode. Unset by
# default, because it is wrong for anyone using a different editor.

# Hooks run with a minimal PATH.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

input=$(cat)
event=$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null)
msg=$(printf '%s' "$input" | jq -r '.message // empty' 2>/dev/null)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)
project=$(basename "${cwd:-Claude Code}")

case "$event" in
    Notification)
        title="Claude Code · ${project}"
        body="${msg:-Claude needs your attention}"
        sound="Glass"
        ;;
    Stop)
        title="Claude Code · ${project}"
        body="Finished — ready for you"
        sound="Submarine"
        ;;
    *)
        title="Claude Code"
        body="${msg:-Event: ${event:-unknown}}"
        sound="Glass"
        ;;
esac

case "$(uname -s)" in
    Darwin)
        if command -v terminal-notifier >/dev/null 2>&1; then
            args=(-title "$title" -message "$body" -sound "$sound"
                  -group "claude-code-${event:-misc}")
            [ -n "${CC_NOTIFY_SENDER:-}" ] && args+=(-sender "$CC_NOTIFY_SENDER")
            terminal-notifier "${args[@]}" >/dev/null 2>&1
        else
            esc() { printf '%s' "$1" | sed 's/"/\\"/g'; }
            osascript -e "display notification \"$(esc "$body")\" with title \"$(esc "$title")\" sound name \"$sound\"" >/dev/null 2>&1
        fi
        ;;
    Linux)
        if command -v notify-send >/dev/null 2>&1; then
            notify-send "$title" "$body" >/dev/null 2>&1
        fi
        ;;
esac

exit 0
