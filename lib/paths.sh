#!/usr/bin/env bash
# Shared state-directory resolution.
#
# The renderer and every hook source this file. That is the point: the status
# line reads files that the hooks write, so both sides must agree on one
# directory. When they disagreed, the session name was written where nothing
# read it and the clock went blank, with no error anywhere.
#
# Resolution order:
#   1. $CC_STATUSLINE_STATE_DIR, if you set it.
#   2. /private/tmp/claude-<uid> on macOS.
#   3. /tmp/claude-<uid> everywhere else.
#
# The uid suffix keeps the directory private per user on a shared machine.

cc_state_dir() {
    if [ -n "${CC_STATUSLINE_STATE_DIR:-}" ]; then
        printf '%s' "$CC_STATUSLINE_STATE_DIR"
        return 0
    fi
    local uid
    uid=$(id -u 2>/dev/null || echo 0)
    if [ -d /private/tmp ]; then
        printf '/private/tmp/claude-%s' "$uid"
    else
        printf '/tmp/claude-%s' "$uid"
    fi
}

# Absolute path to one file inside the state directory.
cc_state_file() {
    printf '%s/%s' "$(cc_state_dir)" "$1"
}

# Create the state directory. Safe to call repeatedly.
cc_ensure_state_dir() {
    mkdir -p "$(cc_state_dir)" 2>/dev/null || true
}

# Name of the file holding the current session name, given a session id.
cc_session_name_file() {
    cc_state_file "claude-session-$1.name"
}

# Claude cannot see its own session id, so it writes a pending file instead.
# The renderer promotes that file on its next draw.
#
# The session id is the key, because it is the only value that is both unique per
# session and present at every call site. This used to key on CLAUDE_CODE_SSE_PORT,
# which is unset in an ordinary terminal -- so every session fell back to one
# shared path and whichever renderer drew first promoted the name, whoever wrote
# it. An empty id is refused rather than keyed, or it recreates that shared path
# under the name "claude-session-pending-.name".
cc_pending_name_file() {
    [ -n "${1:-}" ] || return 1
    cc_state_file "claude-session-pending-$1.name"
}

# Timestamp of the last tool call, written by hooks/record-activity.sh.
cc_activity_file() {
    cc_state_file "claude-last-activity.txt"
}
