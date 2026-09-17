#!/usr/bin/env bash
# Reports the session name as the herdr pane title. Wire it to SessionStart,
# UserPromptSubmit, PreToolUse, PostToolUse, Stop and SessionEnd.
#
# herdr (https://herdr.dev) shows a Claude Code pane with the terminal title
# Claude Code set from the first prompt, which goes stale as the session moves
# on. This hook replaces it with the session name that session-name-check.sh
# keeps current, plus a short activity while a tool runs:
#
#   SessionStart     -> "<name>", or the title cleared when there is no name
#   UserPromptSubmit -> "<name> · thinking"
#   PreToolUse       -> "<name> · editing install.sh", or "<name>" when the
#                       activity normalizes to nothing
#   PostToolUse      -> "<name> · thinking"
#   Stop             -> "<name>"
#   SessionEnd       -> title cleared
#
# It uses `herdr pane report-metadata`, which herdr documents for user hooks
# that run beside its own Claude integration. Metadata is display-only, so the
# integration keeps lifecycle and session-restore authority.
#
# Outside herdr, for subagents, without a name, or when herdr fails, it exits 0
# with no output. A pane title is never worth a failed hook.

# The outside-herdr exit comes first: no cd, no sourcing, no stdin. A socket
# path with no socket file means the server is gone; skip the call and its
# timeout.
[ "${HERDR_ENV:-}" = "1" ] || exit 0
[ -n "${HERDR_PANE_ID:-}" ] || exit 0
if [ -n "${HERDR_SOCKET_PATH:-}" ] && [ ! -S "$HERDR_SOCKET_PATH" ]; then exit 0; fi

# Hooks run with a minimal PATH; jq usually lives in one of these.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
command -v jq >/dev/null 2>&1 || exit 0
herdr_bin="${HERDR_BIN_PATH:-herdr}"
command -v "$herdr_bin" >/dev/null 2>&1 || exit 0

CC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/paths.sh
. "${CC_DIR}/lib/paths.sh"
# shellcheck source=../lib/session-name.sh
. "${CC_DIR}/lib/session-name.sh"

# One jq pass over stdin for every field, one field per line. `s` turns
# anything that is not a string into "" and strips newlines, so each field is
# exactly one line and an empty field is an empty line: `read` never collapses
# anything. (A tab-joined line would: tab is IFS whitespace, and `read` merges
# adjacent tabs, so an empty agent_id would swallow the next field.) try/catch
# keeps a payload of the wrong shape from failing the whole expression, and
# reading stdin straight into jq never holds the payload in a shell variable.
fields=$(jq -r '
    def s: if type == "string" then gsub("[\n\r]+"; " ") else "" end;
    (.hook_event_name | s), (.session_id | s), (.transcript_path | s), (.agent_id | s),
    (.tool_name | s),
    (try (.tool_input.file_path // .tool_input.notebook_path) catch null | s),
    (try .tool_input.description catch null | s)
' 2>/dev/null)
{
    read -r event; read -r session_id; read -r transcript_path; read -r agent_id
    read -r tool_name; read -r tool_path; read -r tool_desc
} <<EOF
$fields
EOF

# A subagent's hooks carry agent_id, and its transcript lives under
# <session>/subagents/agent-<id>.jsonl. Its pane is the parent's; leave it alone.
[ -n "$agent_id" ] && exit 0
case "$transcript_path" in */subagents/agent-*.jsonl) exit 0 ;; esac

# Never let a hung socket outlive Claude Code's own hook timeout.
run_limited() {
    if command -v timeout >/dev/null 2>&1; then timeout 3 "$@"
    elif command -v gtimeout >/dev/null 2>&1; then gtimeout 3 "$@"
    else "$@"; fi
}

report() {
    run_limited "$herdr_bin" pane report-metadata "$HERDR_PANE_ID" \
        --source user:claude-title --agent claude "$@" >/dev/null 2>&1 || true
}

# One line, no escapes, no control or format characters, at most 80 code
# points. \e is ESC, \p{Cc} is every C0 and C1 control, \p{Cf} is every format
# character (bidi overrides, zero-width joiners), so this file carries no raw
# bytes. jq slices by code point, so a multi-byte name is never cut in half.
normalize() {
    printf '%s' "$1" | jq -R -s -r '
        gsub("\\e\\[[0-9;?]*[ -/]*[@-~]"; "")
        | gsub("\\p{Cf}"; "")
        | gsub("\\p{Cc}+"; " ")
        | gsub("^ +| +$"; "")
        | .[0:80]
    ' 2>/dev/null
}

if [ "$event" = "SessionEnd" ]; then
    report --clear-title
    exit 0
fi

# Normalize the name first, so a name that is nothing but control characters
# counts as no name and clears a stale title on SessionStart.
name=$(normalize "$(cc_session_name "$session_id" "$transcript_path")")
if [ -z "$name" ]; then
    [ "$event" = "SessionStart" ] && report --clear-title
    exit 0
fi

# One short phrase for what the tool is doing. Only the tool name, a file's
# last path component and Claude's own description reach the title; a command
# line can carry secrets, so it never does. ${var##*/} instead of basename:
# a path that starts with "-" would be read as an option.
activity() {
    local leaf="${tool_path##*/}"
    case "$tool_name" in
        Edit|Write|MultiEdit|NotebookEdit) printf 'editing %s' "${leaf:-file}" ;;
        Read)               printf 'reading %s' "${leaf:-file}" ;;
        Bash)               printf '%s' "${tool_desc:-running a command}" ;;
        Grep|Glob)          printf 'searching' ;;
        Agent|Task)         printf 'delegating' ;;
        WebFetch|WebSearch) printf 'browsing' ;;
        "")                 printf 'working' ;;
        mcp__*)             printf 'using %s' "${tool_name##*__}" ;;
        *)                  printf 'using %s' "$tool_name" ;;
    esac
}

# The activity is normalized on its own first: one that is nothing but escapes
# or control characters would otherwise leave "<name> ·" behind.
case "$event" in
    SessionStart|Stop)            title="$name" ;;
    UserPromptSubmit|PostToolUse) title="${name} · thinking" ;;
    PreToolUse)
        act=$(normalize "$(activity)")
        title="$name"; [ -n "$act" ] && title="${name} · ${act}" ;;
    *)                            exit 0 ;;
esac

title=$(normalize "$title")
[ -n "$title" ] || exit 0
report --title "$title"
exit 0
