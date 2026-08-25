#!/usr/bin/env bash
# Stop hook. Sets the terminal title to "<session name> — <short path>".
#
# The status line sets the title too, on every draw. This hook covers the case
# where the status line is not enabled, and refreshes the title at the end of
# a turn.

CC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/paths.sh
. "${CC_DIR}/lib/paths.sh"

input=$(cat)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)

session_name=""
if [ -n "$session_id" ]; then
    name_file=$(cc_session_name_file "$session_id")
    [ -f "$name_file" ] && session_name=$(cat "$name_file" 2>/dev/null)
fi

short_path=$(printf '%s' "$cwd" | awk -F'/' '{if (NF>2) print $(NF-1)"/"$NF; else print $0}')

title="${session_name:-Claude Code}"
[ -n "$short_path" ] && title="${title} — ${short_path}"

{ printf '\033]0;%s\007' "$title" > /dev/tty; } 2>/dev/null || true
exit 0
