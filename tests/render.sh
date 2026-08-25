#!/usr/bin/env bash
# Proof that the pieces work together, not just that they parse.
#
# The interesting failure this guards against: the renderer and the hooks each
# resolving a different state directory. When that happens the session name and
# the clock silently stay empty, and nothing reports an error.
#
# Run:  bash tests/render.sh
# Needs: bash, jq, awk, git

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="${ROOT}/tests/fixtures/status.json"

# Refuse to run without a real temp directory. An empty value here would send
# every path below to the filesystem root and report nonsense failures.
WORK="$(mktemp -d 2>/dev/null || true)"
if [ -z "$WORK" ] || [ ! -d "$WORK" ]; then
    WORK="${ROOT}/.test-tmp.$$"
    mkdir -p "$WORK" 2>/dev/null || true
fi
if [ -z "$WORK" ] || [ ! -d "$WORK" ] || [ ! -w "$WORK" ]; then
    echo "error: cannot create a writable temp directory. Set TMPDIR and retry." >&2
    exit 1
fi
export CC_STATUSLINE_STATE_DIR="${WORK}/state"
export CC_STATUSLINE_NO_TITLE=1
export COLUMNS=400
unset CLAUDE_CODE_SSE_PORT
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }
has()  { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

# Render the status line and strip the colour codes.
render() {
    bash "${ROOT}/statusline-command.sh" < "${1:-$FIXTURE}" 2>/dev/null \
        | sed 's/\x1b\[[0-9;]*m//g'
}

SESSION_ID=$(jq -r '.session_id' "$FIXTURE")

echo "== 1. every field renders from a real payload =="
out=$(render)
for probe in "42.5%" "in:1.2M" "out:8.9k" "Opus 5" "high" "wt:fd-017" "Projects/demo-app" "\$3.46" "1h31m" "+128" "-47"; do
    if has "$probe" "$out"; then ok "renders ${probe}"; else bad "renders ${probe}" "$out"; fi
done
if has "██████░░░░░░░░░" "$out"; then ok "context bar fills to 42.5%"; else bad "context bar fills to 42.5%" "$out"; fi
# Regression guard: building the bar with `tr` produced broken UTF-8 on Linux
# while looking correct on macOS.
if printf '%s' "$out" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
    ok "output is valid UTF-8"
else bad "output is valid UTF-8" "$out"; fi

echo
echo "== 2. a pending session name is promoted and shown =="
mkdir -p "$CC_STATUSLINE_STATE_DIR"
printf 'Packaging Run' > "${CC_STATUSLINE_STATE_DIR}/claude-session-pending.name"
out=$(render)
if has "Packaging Run" "$out"; then ok "pending name reaches the status bar"; else bad "pending name reaches the status bar" "$out"; fi
if [ ! -f "${CC_STATUSLINE_STATE_DIR}/claude-session-pending.name" ]; then
    ok "pending file consumed"
else bad "pending file consumed"; fi
if [ -f "${CC_STATUSLINE_STATE_DIR}/claude-session-${SESSION_ID}.name" ]; then
    ok "promoted to claude-session-<id>.name"
else bad "promoted to claude-session-<id>.name"; fi
if [ "$(cat "${CC_STATUSLINE_STATE_DIR}/claude-session-id" 2>/dev/null)" = "$SESSION_ID" ]; then
    ok "session id written back for direct updates"
else bad "session id written back for direct updates"; fi

echo
echo "== 3. the clock the hook writes is the clock the renderer reads =="
printf '{"hook_event_name":"PostToolUse"}' | bash "${ROOT}/hooks/record-activity.sh" > "${WORK}/post.out" 2>/dev/null
stamp=$(cat "${CC_STATUSLINE_STATE_DIR}/claude-last-activity.txt" 2>/dev/null)
if printf '%s' "$stamp" | grep -Eq '^[0-9]{2}:[0-9]{2}:[0-9]{2}$'; then
    ok "PostToolUse wrote a timestamp (${stamp})"
else bad "PostToolUse wrote a timestamp" "got: '${stamp}'"; fi
if [ ! -s "${WORK}/post.out" ]; then ok "PostToolUse stays silent"; else bad "PostToolUse stays silent" "$(cat "${WORK}/post.out")"; fi
out=$(render)
if has "$stamp" "$out"; then ok "that timestamp appears in the status bar"; else bad "that timestamp appears in the status bar" "$out"; fi

echo
echo "== 4. Stop stamps the chat =="
stop_out=$(printf '{"hook_event_name":"Stop"}' | bash "${ROOT}/hooks/record-activity.sh" 2>/dev/null)
if printf '%s' "$stop_out" | jq -e '.systemMessage' >/dev/null 2>&1; then
    ok "Stop emits valid systemMessage JSON"
else bad "Stop emits valid systemMessage JSON" "$stop_out"; fi
if printf '%s' "$stop_out" | jq -re '.systemMessage' 2>/dev/null | grep -Eq '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}'; then
    ok "the chat stamp carries the date and time"
else bad "the chat stamp carries the date and time" "$stop_out"; fi
off=$(printf '{"hook_event_name":"Stop"}' | CC_STATUSLINE_CHAT_STAMP=0 bash "${ROOT}/hooks/record-activity.sh" 2>/dev/null)
if [ -z "$off" ]; then ok "CC_STATUSLINE_CHAT_STAMP=0 suppresses it"; else bad "CC_STATUSLINE_CHAT_STAMP=0 suppresses it" "$off"; fi

echo
echo "== 5. the session-name nag fires only when it should =="
hook_in=$(jq -n --arg s "$SESSION_ID" '{session_id:$s, hook_event_name:"UserPromptSubmit"}')
out=$(printf '%s' "$hook_in" | bash "${ROOT}/hooks/session-name-check.sh" 2>/dev/null)
if [ -z "$out" ]; then ok "silent while the name is fresh"; else bad "silent while the name is fresh" "$out"; fi
rm -f "${CC_STATUSLINE_STATE_DIR}/claude-session-${SESSION_ID}.name"
out=$(printf '%s' "$hook_in" | bash "${ROOT}/hooks/session-name-check.sh" 2>/dev/null)
if has "No session name set" "$out"; then ok "nags when no name exists"; else bad "nags when no name exists" "$out"; fi
printf 'Later' > "${CC_STATUSLINE_STATE_DIR}/claude-session-pending.name"
out=$(printf '%s' "$hook_in" | bash "${ROOT}/hooks/session-name-check.sh" 2>/dev/null)
if [ -z "$out" ]; then ok "silent when a name is already pending"; else bad "silent when a name is already pending" "$out"; fi
rm -f "${CC_STATUSLINE_STATE_DIR}/claude-session-pending.name"

echo
echo "== 6. install is idempotent and does not destroy settings =="
FAKE_PREFIX="${WORK}/install/statusline"
FAKE_SETTINGS="${WORK}/install/settings.json"
mkdir -p "${WORK}/install"
cat > "$FAKE_SETTINGS" <<'JSON'
{ "model": "opus", "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "echo pre-existing" } ] } ] } }
JSON
bash "${ROOT}/install.sh" --prefix "$FAKE_PREFIX" --settings "$FAKE_SETTINGS" >/dev/null 2>&1
bash "${ROOT}/install.sh" --prefix "$FAKE_PREFIX" --settings "$FAKE_SETTINGS" >/dev/null 2>&1
if jq empty "$FAKE_SETTINGS" 2>/dev/null; then ok "settings.json is still valid JSON"; else bad "settings.json is still valid JSON"; fi
n=$(jq --arg p "$FAKE_PREFIX" '[ .hooks[]?[]?.hooks[]? | select((.command // "") | contains($p)) ] | length' "$FAKE_SETTINGS")
if [ "$n" = "4" ]; then ok "four hook entries after two installs (no duplicates)"; else bad "four hook entries after two installs" "got ${n}"; fi
if [ "$(jq -r '.model' "$FAKE_SETTINGS")" = "opus" ]; then ok "unrelated settings preserved"; else bad "unrelated settings preserved"; fi
if jq -e '[ .hooks.Stop[]?.hooks[]? | select(.command == "echo pre-existing") ] | length == 1' "$FAKE_SETTINGS" >/dev/null; then
    ok "pre-existing hook preserved"
else bad "pre-existing hook preserved"; fi
if ls "${FAKE_SETTINGS}".bak-* >/dev/null 2>&1; then ok "a backup was written"; else bad "a backup was written"; fi
if [ -x "${FAKE_PREFIX}/statusline-command.sh" ] && [ -f "${FAKE_PREFIX}/lib/paths.sh" ]; then
    ok "files copied and executable"
else bad "files copied and executable"; fi

echo
echo "== 7. the installed copy renders =="
out=$(bash "${FAKE_PREFIX}/statusline-command.sh" < "$FIXTURE" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g')
if has "Opus 5" "$out"; then ok "installed renderer works from its prefix"; else bad "installed renderer works from its prefix" "$out"; fi

echo
echo "== 8. uninstall removes exactly its own entries =="
bash "${ROOT}/uninstall.sh" --prefix "$FAKE_PREFIX" --settings "$FAKE_SETTINGS" >/dev/null 2>&1
n=$(jq --arg p "$FAKE_PREFIX" '[ .hooks[]?[]?.hooks[]? | select((.command // "") | contains($p)) ] | length' "$FAKE_SETTINGS")
if [ "$n" = "0" ]; then ok "no status line entries remain"; else bad "no status line entries remain" "got ${n}"; fi
if jq -e '[ .hooks.Stop[]?.hooks[]? | select(.command == "echo pre-existing") ] | length == 1' "$FAKE_SETTINGS" >/dev/null; then
    ok "pre-existing hook survived uninstall"
else bad "pre-existing hook survived uninstall"; fi
if jq -e '.statusLine == null' "$FAKE_SETTINGS" >/dev/null; then ok "statusLine removed"; else bad "statusLine removed"; fi
if [ ! -d "$FAKE_PREFIX" ]; then ok "installed files removed"; else bad "installed files removed"; fi

echo
echo "== 9. every script parses =="
for f in "${ROOT}/statusline-command.sh" "${ROOT}/lib/paths.sh" "${ROOT}"/hooks/*.sh "${ROOT}/install.sh" "${ROOT}/uninstall.sh"; do
    if bash -n "$f" 2>/dev/null; then ok "parses $(basename "$f")"; else bad "parses $(basename "$f")"; fi
done

echo
echo "-------------------------------------------"
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
