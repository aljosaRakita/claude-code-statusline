#!/usr/bin/env bash
# Records when Claude last did something. Wire it to BOTH PostToolUse and Stop.
#
# It produces two different things from one file:
#   PostToolUse -> write the timestamp only. The status line reads it for the
#                  clock segment. No message, or you get a stamp per tool call.
#   Stop        -> write the timestamp AND return a systemMessage, which Claude
#                  Code prints into the transcript. That stamps the chat with
#                  the date once per turn, and it is the only way the model
#                  learns the current date and time mid-session.
#
# Set CC_STATUSLINE_CHAT_STAMP=0 to keep the clock but drop the chat stamp.

CC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/paths.sh
. "${CC_DIR}/lib/paths.sh"

input=$(cat)
event=$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null)

cc_ensure_state_dir

now_time=$(date '+%H:%M:%S')
now_date=$(date '+%a %Y-%m-%d')
printf '%s' "$now_time" > "$(cc_activity_file)" 2>/dev/null

if [ "$event" = "Stop" ] && [ "${CC_STATUSLINE_CHAT_STAMP:-1}" != "0" ]; then
    jq -n --arg t "$now_time" --arg d "$now_date" \
        '{systemMessage: ("🕐 " + $d + " " + $t)}'
fi

exit 0
