#!/usr/bin/env bash
# Session name resolution, shared by the renderer and the herdr hook.
#
# Order:
#   1. claude-session-<id>.name, the file Claude manages through the renderer.
#   2. The session summary in sessions-index.json, which sits next to the
#      transcript, or under the encoded project dir when no transcript path is
#      known.
#   3. The first user message in the transcript.
#
# The pending file is not part of this chain on purpose. It is keyed by
# CLAUDE_CODE_SSE_PORT at best and global at worst, so reading it here could
# hand one session's name to another session's pane. Promoting it is the
# renderer's job; this function reads only the promoted file.
#
# Requires lib/paths.sh to be sourced first. Prints the first line of the
# name, or nothing.

# cc_session_name <session_id> [transcript_path] [project_dir]
cc_session_name() {
    local session_id="$1" transcript_path="${2:-}" project_dir="${3:-}"
    local name="" f index_dir

    if [ -n "$session_id" ]; then
        f=$(cc_session_name_file "$session_id")
        [ -f "$f" ] && name=$(head -n1 "$f" 2>/dev/null)
    fi

    if [ -z "$name" ] && [ -n "$session_id" ]; then
        index_dir=""
        if [ -n "$transcript_path" ]; then
            index_dir=$(dirname "$transcript_path")
        elif [ -n "$project_dir" ]; then
            index_dir="$HOME/.claude/projects/$(printf '%s' "$project_dir" | sed 's|^/|-|; s|/|-|g')"
        fi
        if [ -n "$index_dir" ] && [ -f "$index_dir/sessions-index.json" ]; then
            # `strings` drops a summary that is not a string; head -n1 keeps
            # the result to one line whatever the index holds.
            name=$(jq -r --arg sid "$session_id" \
                'first(.entries[]? | select(.sessionId == $sid) | .summary | strings)' \
                "$index_dir/sessions-index.json" 2>/dev/null | head -n1)
        fi
    fi

    if [ -z "$name" ] && [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
        # The first 50 lines, capped at 256 KB, bound the work, whatever the
        # line length; each line is parsed on its own, so a line cut short is
        # dropped by fromjson?, not fatal. Content is a string in old
        # transcripts and a block array in new ones; an empty text block must
        # not hide a later one. Lines that start with "<" are injected
        # <local-command-...> records, not prompts; the renderer has always
        # skipped them and the hook must agree with it.
        name=$(head -n 50 "$transcript_path" | head -c 262144 | jq -R -r '
            fromjson? | select(.type == "user") | .message.content
            | if type == "string" then select(length > 0)
              elif type == "array" then (map(select(.type == "text") | .text | strings | select(length > 0)) | first // empty)
              else empty end
            | gsub("^\\s+"; "") | select(length > 0)
            | select(startswith("<") | not)
        ' 2>/dev/null | head -n1)
    fi

    printf '%s' "$name"
}
