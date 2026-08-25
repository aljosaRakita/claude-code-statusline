#!/usr/bin/env bash
# UserPromptSubmit hook. Nudges Claude to name the session, or to rename it
# when the name has gone stale.
#
# Claude cannot see its own session id, so it names a session by writing the
# pending file this script reports. The status line promotes that file on its
# next draw.

CC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/paths.sh
. "${CC_DIR}/lib/paths.sh"

STALE_MINUTES="${CC_STATUSLINE_STALE_MINUTES:-10}"

input=$(cat)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
[ -z "$session_id" ] && exit 0

name_file=$(cc_session_name_file "$session_id")
pending_file=$(cc_pending_name_file)

# A pending name is already waiting for the next draw. Do not nag again.
[ -f "$pending_file" ] && exit 0

if [ ! -f "$name_file" ]; then
    echo "No session name set. Write one to ${pending_file} reflecting the current task focus."
    exit 0
fi

if [ -n "$(find "$name_file" -mmin "+${STALE_MINUTES}" 2>/dev/null)" ]; then
    current=$(cat "$name_file" 2>/dev/null)
    echo "Session name \"${current}\" was set >${STALE_MINUTES}m ago. Update it if the focus has shifted."
fi

exit 0
