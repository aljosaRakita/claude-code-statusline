#!/usr/bin/env bash
# Claude Code status line renderer.
#
# Claude Code pipes a JSON status payload on stdin and prints whatever this
# writes to stdout. One row, which drops low-priority segments to fit COLUMNS:
#
#   session pct │ model effort │ worktree branch path │ cost duration lines │ clock
#
# Requires jq. Uses awk for arithmetic, so bc is not needed.

CC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/paths.sh
. "${CC_DIR}/lib/paths.sh"

input=$(cat)

RESET="\033[0m"; BOLD="\033[1m"; DIM="\033[2m"
CYAN="\033[36m"; MAGENTA="\033[35m"; YELLOW="\033[33m"; GREEN="\033[32m"
RED="\033[31m"; ORANGE="\033[38;5;208m"; BLUE="\033[34m"; WHITE="\033[97m"; GRAY="\033[90m"

# --- Extract values ---
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty')
project_dir=$(printf '%s' "$input" | jq -r '.workspace.project_dir // empty')
transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
model_display=$(printf '%s' "$input" | jq -r '.model.display_name // empty')
used_pct=$(printf '%s' "$input" | jq -r '.context_window.used_percentage // empty')
cost_usd=$(printf '%s' "$input" | jq -r '.cost.total_cost_usd // empty')
duration_ms=$(printf '%s' "$input" | jq -r '.cost.total_duration_ms // 0')
lines_added=$(printf '%s' "$input" | jq -r '.cost.total_lines_added // 0')
lines_removed=$(printf '%s' "$input" | jq -r '.cost.total_lines_removed // 0')
worktree_name=$(printf '%s' "$input" | jq -r '.worktree.name // empty')

cc_ensure_state_dir

# --- Session name ---
# Priority: the name file Claude manages, then the sessions index summary,
# then the first user message in the transcript.
session_name=""
name_file=$(cc_session_name_file "$session_id")

# Promote a pending name written by Claude, which cannot see the session id.
# The path is computed inside this guard on purpose: an empty session id would
# otherwise key every session to one shared file again.
if [ -n "$session_id" ]; then
    pending_file=$(cc_pending_name_file "$session_id")
    [ -f "$pending_file" ] && mv "$pending_file" "$name_file" 2>/dev/null
fi

# Drop files left behind by sessions that ended over an hour ago: the keyed
# pending names, plus the unkeyed pending and id files the port-keyed scheme
# wrote. An unkeyed pending file is aged out, never promoted -- promoting it
# would hand one session another session's name, which is the bug this keying
# exists to remove.
#
# `! -name '*.name'` keeps the id pattern off a name file whose session id
# happens to begin "id-". No real session id does, since they are UUIDs, but the
# pattern should not depend on that.
find "$(cc_state_dir)" -maxdepth 1 -mmin +60 \
    \( -name 'claude-session-pending-*.name' \
       -o -name 'claude-session-pending.name' \
       -o \( -name 'claude-session-id*' ! -name '*.name' \) \) \
    -delete 2>/dev/null

[ -f "$name_file" ] && session_name=$(cat "$name_file" 2>/dev/null)

if [ -z "$session_name" ] && [ -n "$project_dir" ] && [ -n "$session_id" ]; then
    index_file="$HOME/.claude/projects/$(printf '%s' "$project_dir" | sed 's|^/|-|; s|/|-|g')/sessions-index.json"
    if [ -f "$index_file" ]; then
        session_name=$(jq -r --arg sid "$session_id" \
            '.entries[]? | select(.sessionId == $sid) | .summary // empty' \
            "$index_file" 2>/dev/null)
    fi
fi

if [ -z "$session_name" ] && [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    session_name=$(head -50 "$transcript_path" | jq -r '
        select(.type == "user") | .message.content |
        if type == "string" and (startswith("<") | not) then . else empty end
    ' 2>/dev/null | head -1)
fi

# --- Reasoning effort: payload first, then settings.json ---
effort=$(printf '%s' "$input" | jq -r '.effort.level // .effort_level // empty')
if [ -z "$effort" ] && [ -f "$HOME/.claude/settings.json" ]; then
    effort=$(jq -r '.effortLevel // empty' "$HOME/.claude/settings.json" 2>/dev/null)
fi
effort=${effort:-default}

# --- Context percentage, coloured by band ---
pct_section=""
if [ -n "$used_pct" ]; then
    used_int=${used_pct%.*}
    used_int=${used_int:-0}
    if   [ "$used_int" -ge 90 ]; then pct_color="${BOLD}${RED}"
    elif [ "$used_int" -ge 80 ]; then pct_color="$RED"
    elif [ "$used_int" -ge 75 ]; then pct_color="$ORANGE"
    elif [ "$used_int" -ge 50 ]; then pct_color="$YELLOW"
    elif [ "$used_int" -ge 30 ]; then pct_color="$GREEN"
    else                              pct_color="$GRAY"
    fi
    pct_section="${pct_color}${used_int}%${RESET}"
fi

case "$effort" in
    high)   effort_color="$GREEN" ;;
    medium) effort_color="$YELLOW" ;;
    low)    effort_color="$RED" ;;
    *)      effort_color="$DIM" ;;
esac
model_section="${MAGENTA}${BOLD}${model_display}${RESET} ${effort_color}${effort}${RESET}"

# --- Git branch, with a dirty marker ---
git_section=""
if [ -n "$cwd" ] && git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
    branch=$(git -C "$cwd" --no-optional-locks branch --show-current 2>/dev/null)
    [ -z "$branch" ] && branch="detached"
    [ "${#branch}" -gt 24 ] && branch="${branch:0:24}…"
    dirty=""
    if ! git -C "$cwd" --no-optional-locks diff-index --quiet HEAD -- 2>/dev/null; then
        dirty="${YELLOW}*${RESET}"
    fi
    git_section="${GREEN}${branch}${RESET}${dirty}"
fi

wt_section=""
[ -n "$worktree_name" ] && wt_section="${BLUE}${worktree_name}${RESET}"

short_path=$(printf '%s' "$cwd" | awk -F'/' '{if (NF>2) print $(NF-1)"/"$NF; else print $0}')
path_section="${CYAN}${short_path}${RESET}"

cost_section=""
if [ -n "$cost_usd" ] && [ "$cost_usd" != "0" ]; then
    cost_section="${YELLOW}\$$(printf '%.2f' "$cost_usd" 2>/dev/null || printf '%s' "$cost_usd")${RESET}"
fi

dur_section=""
if [ "${duration_ms:-0}" -gt 0 ] 2>/dev/null; then
    total_secs=$((duration_ms / 1000))
    hours=$((total_secs / 3600))
    minutes=$(((total_secs % 3600) / 60))
    if   [ "$hours" -gt 0 ];   then dur_section="${BLUE}${hours}h${minutes}m${RESET}"
    elif [ "$minutes" -gt 0 ]; then dur_section="${BLUE}${minutes}m${RESET}"
    fi
fi

lines_section=""
if [ "${lines_added:-0}" -gt 0 ] || [ "${lines_removed:-0}" -gt 0 ]; then
    lines_section="${GREEN}+${lines_added}${RESET}${RED}-${lines_removed}${RESET}"
fi

clock_section=""
last_activity=$(cat "$(cc_activity_file)" 2>/dev/null)
[ -n "$last_activity" ] && clock_section="${GRAY}${last_activity}${RESET}"

session_section=""
if [ -n "$session_name" ]; then
    truncated="${session_name:0:20}"
    [ "${#session_name}" -gt 20 ] && truncated="${truncated}…"
    session_section="${WHITE}${BOLD}${truncated}${RESET}"
fi

# Join the non-empty arguments after the first with the first as separator.
join_parts() {
    local sep=$1 joined="" part
    shift
    for part in "$@"; do
        [ -z "$part" ] && continue
        joined="${joined:+${joined}${sep}}${part}"
    done
    printf '%s' "$joined"
}

compose_line() {
    join_parts ' │ ' \
        "$(join_parts ' ' "$session_section" "$pct_section")" \
        "$model_section" \
        "$(join_parts ' ' "$wt_section" "$git_section" "$path_section")" \
        "$(join_parts ' ' "$cost_section" "$dur_section" "$lines_section")" \
        "$clock_section"
}

# Columns the line occupies: strip colours, then drop UTF-8 continuation bytes
# so each character counts once.
visible_width() {
    printf '%b' "$1" | sed $'s/\033\\[[0-9;]*m//g' | LC_ALL=C tr -d '\200-\277' | wc -c | tr -d '[:space:]'
}

# Always one row: drop the lowest-priority segment until the line fits.
line=$(compose_line)
term_width=${COLUMNS:-$(tput cols 2>/dev/null || echo 0)}
if [ "${term_width:-0}" -gt 0 ] 2>/dev/null; then
    for segment in clock_section lines_section dur_section path_section wt_section cost_section session_section; do
        [ "$(visible_width "$line")" -le "$term_width" ] && break
        printf -v "$segment" '%s' ''
        line=$(compose_line)
    done
fi

# Set the terminal title too. Harmless when there is no tty.
if [ "${CC_STATUSLINE_NO_TITLE:-0}" != "1" ]; then
    term_title="${session_name:-Claude Code}"
    [ -n "$short_path" ] && term_title="${term_title} — ${short_path}"
    { printf '\033]0;%s\007' "$term_title" > /dev/tty; } 2>/dev/null || true
fi

printf '%b\n' "$line"
