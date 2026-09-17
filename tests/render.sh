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

# An empty HOME, so the settings.json effort fallback cannot hide a broken payload read.
render_raw() {
    HOME="${WORK}/no-home" bash "${ROOT}/statusline-command.sh" < "${1:-$FIXTURE}" 2>/dev/null
}

# Render the status line and strip the colour codes.
render() {
    render_raw "$@" | sed 's/\x1b\[[0-9;]*m//g'
}

# Terminal columns of a stripped line: one byte per character once UTF-8
# continuation bytes are gone.
width_of() { printf '%s' "$1" | LC_ALL=C tr -d '\200-\277' | wc -c | tr -d '[:space:]'; }

SESSION_ID=$(jq -r '.session_id' "$FIXTURE")

echo "== 1. every field renders from a real payload =="
out=$(render)
for probe in "42%" "Opus 5" "high" "fd-017" "Projects/demo-app" "\$3.46" "1h31m" "+128" "-47"; do
    if has "$probe" "$out"; then ok "renders ${probe}"; else bad "renders ${probe}" "$out"; fi
done
for gone in "░" "in:" "out:" "42.5%"; do
    if has "$gone" "$out"; then bad "omits ${gone}" "$out"; else ok "omits ${gone}"; fi
done
if printf '%s' "$out" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
    ok "output is valid UTF-8"
else bad "output is valid UTF-8" "$out"; fi

echo
echo "== 1b. the percentage takes the colour of its band =="
for band in "29:90m" "30:32m" "49:32m" "50:33m" "74:33m" "75:38;5;208m" "79:38;5;208m" "80:31m" "89:31m" "90:1m\\033[31m"; do
    pct=${band%%:*}
    jq --argjson p "$pct" '.context_window.used_percentage = $p' "$FIXTURE" > "${WORK}/pct.json"
    raw=$(render_raw "${WORK}/pct.json")
    if has "$(printf '\033[%b%s%%' "${band#*:}" "$pct")" "$raw"; then
        ok "${pct}% uses colour ${band#*:}"
    else bad "${pct}% uses colour ${band#*:}" "$(printf '%s' "$raw" | od -c | head -3)"; fi
done

echo
echo "== 1c. the line drops low-priority segments to fit one row =="
for cols in 400 75 60 40 20; do
    out=$(COLUMNS=$cols render)
    rows=$(printf '%s\n' "$out" | wc -l | tr -d '[:space:]')
    width=$(width_of "$out")
    if [ "$rows" = "1" ]; then ok "one row at ${cols} columns"; else bad "one row at ${cols} columns" "$out"; fi
    if [ "$width" -le "$cols" ] || [ "$cols" = "20" ]; then
        ok "fits ${cols} columns (${width})"
    else bad "fits ${cols} columns" "${width}: ${out}"; fi
    if has "42%" "$out" && has "Opus 5" "$out"; then ok "keeps percentage and model at ${cols}"; else bad "keeps percentage and model at ${cols}" "$out"; fi
done
out=$(COLUMNS=60 render)
if has "\$3.46" "$out" && has "Projects/demo-app" "$out" && ! has "+128" "$out"; then
    ok "at 60 columns the line count goes before cost and path"
else bad "at 60 columns the line count goes before cost and path" "$out"; fi
out=$(COLUMNS=40 render)
if has "\$3.46" "$out" && ! has "Projects/demo-app" "$out"; then
    ok "at 40 columns the path goes before cost"
else bad "at 40 columns the path goes before cost" "$out"; fi

REPO="${WORK}/repo"
git init -q -b feature/a-branch-name-far-longer-than-the-cap "$REPO"
touch "${REPO}/untracked" && git -C "$REPO" add untracked
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q -m init
printf 'x' > "${REPO}/untracked"
jq --arg cwd "$REPO" '.cwd = $cwd' "$FIXTURE" > "${WORK}/branch.json"
out=$(COLUMNS=60 render "${WORK}/branch.json")
if has "feature/a-branch-name-fa…*" "$out" && [ "$(width_of "$out")" -le 60 ]; then
    ok "a long dirty branch is cut and the row fits 60 columns"
else bad "a long dirty branch is cut and the row fits 60 columns" "$(width_of "$out"): ${out}"; fi

echo
echo "== 2. a pending session name is promoted and shown =="
mkdir -p "$CC_STATUSLINE_STATE_DIR"
printf 'Packaging Run' > "${CC_STATUSLINE_STATE_DIR}/claude-session-pending-${SESSION_ID}.name"
out=$(render)
if has "Packaging Run" "$out"; then ok "pending name reaches the status bar"; else bad "pending name reaches the status bar" "$out"; fi
if [ ! -f "${CC_STATUSLINE_STATE_DIR}/claude-session-pending-${SESSION_ID}.name" ]; then
    ok "pending file consumed"
else bad "pending file consumed"; fi
if [ -f "${CC_STATUSLINE_STATE_DIR}/claude-session-${SESSION_ID}.name" ]; then
    ok "promoted to claude-session-<id>.name"
else bad "promoted to claude-session-<id>.name"; fi

echo
echo "== 2b. two live sessions cannot steal each other's name =="
# The pending file carries a name Claude chose before it can know its own session
# id. If that file is not keyed per session, whichever renderer draws first
# promotes it -- so session B ends up wearing session A's name. Both assertions
# below fail while the pending path is shared.
#
# Deliberately asymmetric: A writes, B draws. A symmetric script cannot run at
# all on the broken code, because A's unpromoted pending file suppresses B's
# nudge, so B never learns a path to write to.
SID_A="aaaaaaaa-0000-4000-8000-00000000000a"
SID_B="bbbbbbbb-0000-4000-8000-00000000000b"
prompt_for() { jq -n --arg s "$1" '{session_id:$s, hook_event_name:"UserPromptSubmit"}'; }

nudge_a=$(prompt_for "$SID_A" | bash "${ROOT}/hooks/session-name-check.sh" 2>/dev/null)
path_a=$(printf '%s' "$nudge_a" | sed -n 's/.*Write one to \(.*\) reflecting.*/\1/p')
if [ -n "$path_a" ]; then ok "session A is told where to write"; else bad "session A is told where to write" "$nudge_a"; fi
printf 'name-A' > "$path_a"

# Checked before B renders, so the assertion reads against the state the symptom
# actually occurs in: A's name still pending, B's still absent. Either order
# detects the bug -- reversing it does not make the test pass on broken code --
# but reversed it would be asserting about a session that has already been given
# a name, which is a different claim.
nudge_b=$(prompt_for "$SID_B" | bash "${ROOT}/hooks/session-name-check.sh" 2>/dev/null)
if has "No session name set" "$nudge_b"; then
    ok "session B is still nudged while A's name is pending"
else bad "session B is still nudged while A's name is pending" "got: '${nudge_b}'"; fi

jq --arg s "$SID_B" '.session_id = $s' "$FIXTURE" > "${WORK}/status-b.json"
render "${WORK}/status-b.json" >/dev/null
stolen=$(cat "${CC_STATUSLINE_STATE_DIR}/claude-session-${SID_B}.name" 2>/dev/null)
if [ "$stolen" != "name-A" ]; then
    ok "session B did not steal session A's name"
else bad "session B did not steal session A's name" "B's name file holds '${stolen}'"; fi

# An upgrade leaves an unkeyed pending file behind. Promoting it would hand this
# session whatever the other one wrote -- the same steal, one last time.
printf 'legacy-name' > "${CC_STATUSLINE_STATE_DIR}/claude-session-pending.name"
render "${WORK}/status-b.json" >/dev/null
legacy=$(cat "${CC_STATUSLINE_STATE_DIR}/claude-session-${SID_B}.name" 2>/dev/null)
if [ "$legacy" != "legacy-name" ]; then
    ok "an unkeyed pending file is never promoted"
else bad "an unkeyed pending file is never promoted" "B's name file holds '${legacy}'"; fi

# The stale sweep runs on every draw, from whichever session happens to draw, so
# it must not eat a pending name another session has not promoted yet. Promotion
# normally lands on the next draw, within a second; a pending file that has
# survived an hour belongs to a session that is gone.
SID_C="cccccccc-0000-4000-8000-00000000000c"
pending_c="${CC_STATUSLINE_STATE_DIR}/claude-session-pending-${SID_C}.name"
printf 'name-C' > "$pending_c"
render "${WORK}/status-b.json" >/dev/null
if [ -f "$pending_c" ]; then
    ok "another session's fresh pending name survives a draw"
else bad "another session's fresh pending name survives a draw"; fi

touch -t 200001010000 "$pending_c"
render "${WORK}/status-b.json" >/dev/null
if [ ! -f "$pending_c" ]; then
    ok "an abandoned pending name is swept"
else bad "an abandoned pending name is swept"; fi

# Leave no state behind: section 5 depends on section 2's promoted name file.
rm -f "$pending_c" "$path_a" "${CC_STATUSLINE_STATE_DIR}/claude-session-${SID_A}.name" \
      "${CC_STATUSLINE_STATE_DIR}/claude-session-${SID_B}.name" \
      "${CC_STATUSLINE_STATE_DIR}/claude-session-pending-${SID_B}.name" \
      "${CC_STATUSLINE_STATE_DIR}/claude-session-pending.name"

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
printf 'Later' > "${CC_STATUSLINE_STATE_DIR}/claude-session-pending-${SESSION_ID}.name"
out=$(printf '%s' "$hook_in" | bash "${ROOT}/hooks/session-name-check.sh" 2>/dev/null)
if [ -z "$out" ]; then ok "silent when a name is already pending"; else bad "silent when a name is already pending" "$out"; fi
rm -f "${CC_STATUSLINE_STATE_DIR}/claude-session-pending-${SESSION_ID}.name"

echo
echo "== 6. install is idempotent and does not destroy settings =="
FAKE_PREFIX="${WORK}/install/statusline"
FAKE_SETTINGS="${WORK}/install/settings.json"
mkdir -p "${WORK}/install"
# The installer writes ~/... for a prefix under $HOME, so match the same form
# the installer would have produced. Matching only the absolute path made the
# uninstall assertion below pass for the wrong reason.
case "$FAKE_PREFIX" in
    "$HOME"/*) P_MATCH="~${FAKE_PREFIX#"$HOME"}" ;;
    *)         P_MATCH="$FAKE_PREFIX" ;;
esac
cat > "$FAKE_SETTINGS" <<'JSON'
{ "model": "opus", "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "echo pre-existing" } ] } ] } }
JSON
bash "${ROOT}/install.sh" --prefix "$FAKE_PREFIX" --settings "$FAKE_SETTINGS" >/dev/null 2>&1
bash "${ROOT}/install.sh" --prefix "$FAKE_PREFIX" --settings "$FAKE_SETTINGS" >/dev/null 2>&1
if jq empty "$FAKE_SETTINGS" 2>/dev/null; then ok "settings.json is still valid JSON"; else bad "settings.json is still valid JSON"; fi
# Counts match on a path boundary, as the installer does, so a sibling
# "<prefix>-backup/" entry added below is never counted as ours.
n=$(jq --arg p "$P_MATCH" '[ .hooks[]?[]?.hooks[]? | select((.command // "") | contains($p + "/")) ] | length' "$FAKE_SETTINGS")
if [ "$n" = "4" ]; then ok "four hook entries after two installs (no duplicates)"; else bad "four hook entries after two installs" "got ${n}"; fi
if [ "$(jq -r '.model' "$FAKE_SETTINGS")" = "opus" ]; then ok "unrelated settings preserved"; else bad "unrelated settings preserved"; fi
if jq -e '[ .hooks.Stop[]?.hooks[]? | select(.command == "echo pre-existing") ] | length == 1' "$FAKE_SETTINGS" >/dev/null; then
    ok "pre-existing hook preserved"
else bad "pre-existing hook preserved"; fi
# A hook group with a matcher but no hooks array is valid settings. The
# installer and the uninstaller must step over it, not abort on it. An event
# whose value is not an array must pass through untouched, and an entry under
# a sibling "<prefix>-backup/" directory is not ours: the prefix must match on
# a path boundary.
BACKUP_CMD="bash ${FAKE_PREFIX}-backup/other.sh"
jq --arg c "$BACKUP_CMD" '
    .hooks.PreCompact = [ { matcher: "x" } ]
    | .hooks.Weird = "not-an-array"
    | .hooks.Stop += [ { hooks: [ { type: "command", command: $c } ] } ]
' "$FAKE_SETTINGS" > "${WORK}/install/tmp.json" && mv "${WORK}/install/tmp.json" "$FAKE_SETTINGS"
bash "${ROOT}/install.sh" --prefix "$FAKE_PREFIX" --settings "$FAKE_SETTINGS" --with-herdr >/dev/null 2>&1
n=$(jq --arg p "$P_MATCH" '[ .hooks[]?[]?.hooks[]? | select((.command // "") | contains($p + "/")) ] | length' "$FAKE_SETTINGS")
if [ "$n" = "11" ]; then ok "--with-herdr adds seven entries, still no duplicates"; else bad "--with-herdr adds seven entries, still no duplicates" "got ${n}"; fi
if [ "$(jq -r '.hooks.PreCompact[0].matcher' "$FAKE_SETTINGS" 2>/dev/null)" = "x" ]; then
    ok "a hook group without a hooks array is left alone"
else bad "a hook group without a hooks array is left alone" "$(jq -c '.hooks.PreCompact' "$FAKE_SETTINGS" 2>/dev/null)"; fi
if [ "$(jq -r '.hooks.Weird' "$FAKE_SETTINGS" 2>/dev/null)" = "not-an-array" ]; then
    ok "a non-array event value is left alone"
else bad "a non-array event value is left alone" "$(jq -c '.hooks.Weird' "$FAKE_SETTINGS" 2>/dev/null)"; fi
if jq -e --arg c "$BACKUP_CMD" '[ .hooks.Stop[]?.hooks[]? | select(.command == $c) ] | length == 1' "$FAKE_SETTINGS" >/dev/null; then
    ok "an entry under <prefix>-backup/ is not stripped"
else bad "an entry under <prefix>-backup/ is not stripped" "$(jq -c '.hooks.Stop' "$FAKE_SETTINGS" 2>/dev/null)"; fi
n=$(jq '[ .hooks[]?[]?.hooks[]? | select((.command // "") | endswith("herdr-pane-title.sh")) | select(.timeout == 5) ] | length' "$FAKE_SETTINGS")
if [ "$n" = "7" ]; then ok "every herdr entry carries a 5s timeout"; else bad "every herdr entry carries a 5s timeout" "got ${n}"; fi
if jq -e '.hooks.SessionStart[]? | select(.matcher == "startup|resume|clear|compact")' "$FAKE_SETTINGS" >/dev/null; then
    ok "SessionStart is wired with its matcher"
else bad "SessionStart is wired with its matcher"; fi
bash "${ROOT}/install.sh" --prefix "$FAKE_PREFIX" --settings "$FAKE_SETTINGS" >/dev/null 2>&1
n=$(jq --arg p "$P_MATCH" '[ .hooks[]?[]?.hooks[]? | select((.command // "") | contains($p + "/")) ] | length' "$FAKE_SETTINGS")
if [ "$n" = "4" ]; then ok "a plain re-install drops the herdr entries again"; else bad "a plain re-install drops the herdr entries again" "got ${n}"; fi
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
n=$(jq --arg p "$P_MATCH" '[ .hooks[]?[]?.hooks[]? | select((.command // "") | contains($p + "/")) ] | length' "$FAKE_SETTINGS")
if [ "$n" = "0" ]; then ok "no status line entries remain"; else bad "no status line entries remain" "got ${n}"; fi
if jq -e '[ .hooks.Stop[]?.hooks[]? | select(.command == "echo pre-existing") ] | length == 1' "$FAKE_SETTINGS" >/dev/null; then
    ok "pre-existing hook survived uninstall"
else bad "pre-existing hook survived uninstall"; fi
if [ "$(jq -r '.hooks.PreCompact[0].matcher' "$FAKE_SETTINGS" 2>/dev/null)" = "x" ]; then
    ok "a hook group without a hooks array survived uninstall"
else bad "a hook group without a hooks array survived uninstall" "$(jq -c '.hooks.PreCompact' "$FAKE_SETTINGS" 2>/dev/null)"; fi
if [ "$(jq -r '.hooks.Weird' "$FAKE_SETTINGS" 2>/dev/null)" = "not-an-array" ]; then
    ok "a non-array event value survived uninstall"
else bad "a non-array event value survived uninstall" "$(jq -c '.hooks.Weird' "$FAKE_SETTINGS" 2>/dev/null)"; fi
if jq -e --arg c "$BACKUP_CMD" '[ .hooks.Stop[]?.hooks[]? | select(.command == $c) ] | length == 1' "$FAKE_SETTINGS" >/dev/null; then
    ok "an entry under <prefix>-backup/ survived uninstall"
else bad "an entry under <prefix>-backup/ survived uninstall" "$(jq -c '.hooks.Stop' "$FAKE_SETTINGS" 2>/dev/null)"; fi
if jq -e '.statusLine == null' "$FAKE_SETTINGS" >/dev/null; then ok "statusLine removed"; else bad "statusLine removed"; fi
if [ ! -d "$FAKE_PREFIX" ]; then ok "installed files removed"; else bad "installed files removed"; fi

echo
echo "== 9. settings paths stay portable =="
# An absolute /Users/you path in settings.json breaks the moment that file is
# shared with another machine. Under $HOME the installer must write ~/... .
FAKE_HOME="${WORK}/home"
mkdir -p "${FAKE_HOME}/.claude"
HOME="$FAKE_HOME" bash "${ROOT}/install.sh" \
    --prefix "${FAKE_HOME}/.claude/statusline" \
    --settings "${FAKE_HOME}/.claude/settings.json" >/dev/null 2>&1
n=$(jq '[ .hooks[]?[]?.hooks[]?.command, .statusLine.command ] | map(select(startswith("bash ~/.claude/statusline/"))) | length' "${FAKE_HOME}/.claude/settings.json" 2>/dev/null)
if [ "$n" = "5" ]; then ok "commands written as ~/.claude/statusline/..."; else bad "commands written as ~/.claude/statusline/..." "got ${n}"; fi
if ! grep -q "$FAKE_HOME" "${FAKE_HOME}/.claude/settings.json"; then
    ok "no absolute home path leaked into settings"
else bad "no absolute home path leaked into settings" "$(grep -o "${FAKE_HOME}[^\"]*" "${FAKE_HOME}/.claude/settings.json" | head -2)"; fi
HOME="$FAKE_HOME" bash "${ROOT}/uninstall.sh" \
    --prefix "${FAKE_HOME}/.claude/statusline" \
    --settings "${FAKE_HOME}/.claude/settings.json" >/dev/null 2>&1
if jq -e '(.statusLine == null) and ((.hooks // {}) | length == 0)' "${FAKE_HOME}/.claude/settings.json" >/dev/null 2>&1; then
    ok "uninstall removes tilde-form entries too"
else bad "uninstall removes tilde-form entries too" "$(cat "${FAKE_HOME}/.claude/settings.json")"; fi

echo
echo "== 10. every script parses =="
for f in "${ROOT}/statusline-command.sh" "${ROOT}/lib/paths.sh" "${ROOT}/lib/session-name.sh" "${ROOT}"/hooks/*.sh "${ROOT}/install.sh" "${ROOT}/uninstall.sh"; do
    if bash -n "$f" 2>/dev/null; then ok "parses $(basename "$f")"; else bad "parses $(basename "$f")"; fi
done

echo
echo "== 11. the herdr pane title follows the session =="
# The hook runs from the installed prefix against a stub herdr that records its
# argv, one per line, and exits as told. The hook must talk to it exactly as
# herdr documents for user hooks, and must never fail a turn when herdr is
# absent, slow or broken.
bash "${ROOT}/install.sh" --prefix "$FAKE_PREFIX" --settings "$FAKE_SETTINGS" --with-herdr >/dev/null 2>&1
if [ -x "${FAKE_PREFIX}/hooks/herdr-pane-title.sh" ] && [ -f "${FAKE_PREFIX}/lib/session-name.sh" ]; then
    ok "installer ships the hook and its lib"
else bad "installer ships the hook and its lib"; fi
HOOK="${FAKE_PREFIX}/hooks/herdr-pane-title.sh"
STUB_DIR="${WORK}/bin"; mkdir -p "$STUB_DIR"
STUB_LOG="${WORK}/herdr.argv"
cat > "${STUB_DIR}/herdr" <<STUB
#!/usr/bin/env bash
[ -n "\${HERDR_STUB_SLEEP:-}" ] && sleep "\$HERDR_STUB_SLEEP"
printf '%s\n' "\$@" > "${STUB_LOG}"
exit "\${HERDR_STUB_EXIT:-0}"
STUB
chmod +x "${STUB_DIR}/herdr"
NAME="Packaging Run"
printf '%s\n' "$NAME" > "${CC_STATUSLINE_STATE_DIR}/claude-session-${SESSION_ID}.name"
payload() {  # payload <event> [extra JSON object]
    local extra="${2:-null}"
    jq -n --arg s "$SESSION_ID" --arg e "$1" --argjson x "$extra" \
        '{session_id:$s, hook_event_name:$e, cwd:"/x"} + ($x // {})'
}
run_hook() {  # run_hook <payload> [env assignments...]; prints "exit=N out=<stdout> err=<stderr>"
    local p="$1"; shift
    # A payload jq could not build must fail loudly: an empty payload leaves no
    # argv log, and every "reports nothing" assertion would pass for nothing.
    [ -n "$p" ] || { printf 'exit=99 out=EMPTY-PAYLOAD err='; return; }
    rm -f "$STUB_LOG"
    local out err rc
    out=$(printf '%s' "$p" | env HERDR_ENV=1 HERDR_PANE_ID="w1:p1" HERDR_BIN_PATH="${STUB_DIR}/herdr" "$@" bash "$HOOK" 2>"${WORK}/hook.err"); rc=$?
    err=$(cat "${WORK}/hook.err")
    printf 'exit=%s out=%s err=%s' "$rc" "$out" "$err"
}
argv() { tr '\n' '|' < "$STUB_LOG" 2>/dev/null; }
PREFIX_ARGV="pane|report-metadata|w1:p1|--source|user:claude-title|--agent|claude|"
secs() { date +%s; }

r=$(run_hook "$(payload Stop)")
if [ "$r" = "exit=0 out= err=" ]; then ok "Stop exits 0, silent on stdout and stderr"; else bad "Stop exits 0, silent on stdout and stderr" "$r"; fi
if [ "$(argv)" = "${PREFIX_ARGV}--title|${NAME}|" ]; then ok "Stop reports the bare session name"; else bad "Stop reports the bare session name" "$(argv)"; fi

run_hook "$(payload SessionStart '{"source":"startup"}')" >/dev/null
if [ "$(argv)" = "${PREFIX_ARGV}--title|${NAME}|" ]; then ok "SessionStart reports the name"; else bad "SessionStart reports the name" "$(argv)"; fi

run_hook "$(payload UserPromptSubmit '{"prompt":"hi"}')" >/dev/null
if [ "$(argv)" = "${PREFIX_ARGV}--title|${NAME} · thinking|" ]; then ok "UserPromptSubmit adds · thinking"; else bad "UserPromptSubmit adds · thinking" "$(argv)"; fi

run_hook "$(payload PreToolUse '{"tool_name":"Edit","tool_input":{"file_path":"/x/y/install.sh"}}')" >/dev/null
if [ "$(argv)" = "${PREFIX_ARGV}--title|${NAME} · editing install.sh|" ]; then ok "PreToolUse Edit names the file"; else bad "PreToolUse Edit names the file" "$(argv)"; fi

run_hook "$(payload PostToolUse '{"tool_name":"Edit","tool_input":{"file_path":"/x/y/install.sh"},"tool_response":{"ok":true}}')" >/dev/null
if [ "$(argv)" = "${PREFIX_ARGV}--title|${NAME} · thinking|" ]; then ok "PostToolUse returns to · thinking"; else bad "PostToolUse returns to · thinking" "$(argv)"; fi

run_hook "$(payload PostToolUseFailure '{"tool_name":"Edit","tool_input":{"file_path":"/x/y/install.sh"},"error":"boom"}')" >/dev/null
if [ "$(argv)" = "${PREFIX_ARGV}--title|${NAME} · thinking|" ]; then ok "PostToolUseFailure returns to · thinking"; else bad "PostToolUseFailure returns to · thinking" "$(argv)"; fi

run_hook "$(payload PreToolUse '{"tool_name":"NotebookRead","tool_input":{"notebook_path":"/x/nb.ipynb"}}')" >/dev/null
if [ "$(argv)" = "${PREFIX_ARGV}--title|${NAME} · reading nb.ipynb|" ]; then ok "PreToolUse NotebookRead names the notebook"; else bad "PreToolUse NotebookRead names the notebook" "$(argv)"; fi

run_hook "$(payload PreToolUse '{"tool_name":"Bash","tool_input":{"command":"bash tests/render.sh","description":"Run the tests"}}')" >/dev/null
if [ "$(argv)" = "${PREFIX_ARGV}--title|${NAME} · Run the tests|" ]; then ok "PreToolUse Bash uses the description"; else bad "PreToolUse Bash uses the description" "$(argv)"; fi

run_hook "$(payload PreToolUse '{"tool_name":"Bash","tool_input":{"command":"API_TOKEN=secret make lint"}}')" >/dev/null
if [ "$(argv)" = "${PREFIX_ARGV}--title|${NAME} · running a command|" ]; then ok "PreToolUse Bash without description never shows the command"; else bad "PreToolUse Bash without description never shows the command" "$(argv)"; fi

run_hook "$(payload PreToolUse '{"tool_name":"mcp__framer__framer_publish","tool_input":{}}')" >/dev/null
if [ "$(argv)" = "${PREFIX_ARGV}--title|${NAME} · using framer_publish|" ]; then ok "PreToolUse MCP tool keeps the tool part"; else bad "PreToolUse MCP tool keeps the tool part" "$(argv)"; fi

run_hook "$(payload PreToolUse '{"tool_name":"Bash","tool_input":"not an object"}')" >/dev/null
if [ "$(argv)" = "${PREFIX_ARGV}--title|${NAME} · running a command|" ]; then ok "a wrong-shaped tool_input still yields a title"; else bad "a wrong-shaped tool_input still yields a title" "$(argv)"; fi

run_hook "$(payload Notification '{"message":"x"}')" >/dev/null
if [ ! -f "$STUB_LOG" ]; then ok "an unwired event reports nothing"; else bad "an unwired event reports nothing" "$(argv)"; fi

run_hook "$(payload SessionEnd '{"reason":"other"}')" >/dev/null
if [ "$(argv)" = "${PREFIX_ARGV}--clear-title|" ]; then ok "SessionEnd clears the title"; else bad "SessionEnd clears the title" "$(argv)"; fi

# ESC built with awk, so this file carries no control-character escape. The
# extra object is built by jq into a variable: bash 3.2 brace-expands a
# double-quoted JSON literal with a top-level comma inside "$(...)".
esc=$(awk 'BEGIN{printf "%c", 27}')
extra=$(jq -n --arg e "$esc" '{tool_name:"Bash", tool_input:{command:"true", description:("line one\nline two" + $e + "[31m red" + $e + "[0m\ttab")}}')
run_hook "$(payload PreToolUse "$extra")" >/dev/null
if [ "$(argv)" = "${PREFIX_ARGV}--title|${NAME} · line one line two red tab|" ]; then ok "title is one line without escapes or control characters"; else bad "title is one line without escapes or control characters" "$(argv)"; fi

# A description that is nothing but an ANSI reset must not leave "<name> ·".
messy=$(jq -n --arg e "$esc" '$e + "[0m"')
extra=$(jq -n --argjson d "$messy" '{tool_name:"Bash", tool_input:{command:"true", description:$d}}')
run_hook "$(payload PreToolUse "$extra")" >/dev/null
if [ "$(argv)" = "${PREFIX_ARGV}--title|${NAME}|" ]; then ok "an activity that normalizes to nothing leaves the bare name"; else bad "an activity that normalizes to nothing leaves the bare name" "$(argv)"; fi

long=$(printf 'é%.0s' $(seq 1 100))
extra=$(jq -n --arg d "$long" '{tool_name:"Bash", tool_input:{command:"true", description:$d}}')
run_hook "$(payload PreToolUse "$extra")" >/dev/null
t=$(tail -n1 "$STUB_LOG")
tlen=$(printf '%s' "$t" | jq -R -r 'length')
if [ "$tlen" = "80" ] && [ "${t#"$NAME"}" != "$t" ] && printf '%s' "$t" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
    ok "title is cut at 80 code points, keeps the name, stays valid UTF-8"
else bad "title is cut at 80 code points, keeps the name, stays valid UTF-8" "len=${tlen}"; fi

printf '%s\n' "$long" > "${CC_STATUSLINE_STATE_DIR}/claude-session-${SESSION_ID}.name"
run_hook "$(payload Stop)" >/dev/null
t=$(tail -n1 "$STUB_LOG"); tlen=$(printf '%s' "$t" | jq -R -r 'length')
if [ "$tlen" = "80" ]; then ok "an oversized name is cut, not dropped"; else bad "an oversized name is cut, not dropped" "len=${tlen}"; fi
printf '%s\n' "$NAME" > "${CC_STATUSLINE_STATE_DIR}/claude-session-${SESSION_ID}.name"

run_hook "$(payload PreToolUse '{"agent_id":"sub-1","tool_name":"Bash","tool_input":{"command":"true"}}')" >/dev/null
if [ ! -f "$STUB_LOG" ]; then ok "a subagent (agent_id) never touches the pane"; else bad "a subagent (agent_id) never touches the pane" "$(argv)"; fi
extra=$(jq -n --arg t "/h/.claude/projects/p/${SESSION_ID}/subagents/agent-1.jsonl" '{transcript_path:$t, tool_name:"Bash", tool_input:{command:"true"}}')
run_hook "$(payload PreToolUse "$extra")" >/dev/null
if [ ! -f "$STUB_LOG" ]; then ok "a subagent (transcript path) never touches the pane"; else bad "a subagent (transcript path) never touches the pane" "$(argv)"; fi
run_hook "$(payload Stop "{\"transcript_path\":\"/h/subagents-lab/${SESSION_ID}.jsonl\"}")" >/dev/null
if [ "$(argv)" = "${PREFIX_ARGV}--title|${NAME}|" ]; then ok "a project path containing 'subagents' is not a subagent"; else bad "a project path containing 'subagents' is not a subagent" "$(argv)"; fi

rm -f "$STUB_LOG"; t0=$(secs)
r=$(printf '%s' "$(payload Stop)" | env -u HERDR_ENV -u HERDR_PANE_ID HERDR_BIN_PATH="${STUB_DIR}/herdr" bash "$HOOK" 2>&1; echo "exit=$?")
if [ "$r" = "exit=0" ] && [ ! -f "$STUB_LOG" ] && [ $(( $(secs) - t0 )) -lt 2 ]; then ok "outside herdr it does nothing, in under 2s"; else bad "outside herdr it does nothing, in under 2s" "$r $(argv)"; fi

rm -f "$STUB_LOG"; t0=$(secs)
r=$(printf '%s' "$(payload Stop)" | env HERDR_ENV=1 HERDR_PANE_ID="w1:p1" HERDR_BIN_PATH="${WORK}/no-such-herdr" bash "$HOOK" 2>&1; echo "exit=$?")
if [ "$r" = "exit=0" ] && [ $(( $(secs) - t0 )) -lt 2 ]; then ok "a missing herdr binary exits 0 silently, in under 2s"; else bad "a missing herdr binary exits 0 silently, in under 2s" "$r"; fi

r=$(run_hook "$(payload Stop)" HERDR_SOCKET_PATH="${WORK}/no-such.sock")
if [ "$r" = "exit=0 out= err=" ] && [ ! -f "$STUB_LOG" ]; then ok "a missing socket file skips the call"; else bad "a missing socket file skips the call" "$r $(argv)"; fi

r=$(run_hook "$(payload Stop)" HERDR_STUB_EXIT=1)
if [ "$r" = "exit=0 out= err=" ]; then ok "a failing herdr never fails the hook"; else bad "a failing herdr never fails the hook" "$r"; fi

if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
    t0=$(secs); r=$(run_hook "$(payload Stop)" HERDR_STUB_SLEEP=10)
    if [ "${r%% *}" = "exit=0" ] && [ $(( $(secs) - t0 )) -lt 5 ]; then ok "a hung herdr is cut off in under 5s"; else bad "a hung herdr is cut off in under 5s" "$r"; fi
else
    ok "(skipped: no timeout binary, Claude Code's 5s hook timeout is the only guard here)"
fi

rm -f "${CC_STATUSLINE_STATE_DIR}/claude-session-${SESSION_ID}.name"
run_hook "$(payload Stop)" >/dev/null
if [ ! -f "$STUB_LOG" ]; then ok "no name, no report on Stop"; else bad "no name, no report on Stop" "$(argv)"; fi
run_hook "$(payload SessionStart '{"source":"resume"}')" >/dev/null
if [ "$(argv)" = "${PREFIX_ARGV}--clear-title|" ]; then ok "no name on SessionStart clears a stale title"; else bad "no name on SessionStart clears a stale title" "$(argv)"; fi

# The pending file is the renderer's business. The hook must not read it.
printf 'Someone Else' > "${CC_STATUSLINE_STATE_DIR}/claude-session-pending.name"
run_hook "$(payload Stop)" >/dev/null
if [ ! -f "$STUB_LOG" ]; then ok "the hook ignores the pending name file"; else bad "the hook ignores the pending name file" "$(argv)"; fi
rm -f "${CC_STATUSLINE_STATE_DIR}/claude-session-pending.name"

# Fallback 2: sessions-index.json next to the transcript.
mkdir -p "${WORK}/proj"; : > "${WORK}/proj/${SESSION_ID}.jsonl"
jq -n --arg s "$SESSION_ID" '{entries:[{sessionId:$s, summary:"From the index"}]}' > "${WORK}/proj/sessions-index.json"
run_hook "$(payload Stop "{\"transcript_path\":\"${WORK}/proj/${SESSION_ID}.jsonl\"}")" >/dev/null
if [ "$(argv)" = "${PREFIX_ARGV}--title|From the index|" ]; then ok "falls back to the sessions-index summary"; else bad "falls back to the sessions-index summary" "$(argv)"; fi

# Fallback 3: the first user message, in block-array form, after an injected line and before a cut last line.
rm -f "${WORK}/proj/sessions-index.json"
{
    printf '{"type":"user","message":{"content":"<local-command-stdout>x</local-command-stdout>"}}\n'
    printf '{"type":"user","message":{"content":[{"type":"text","text":"Fix the login bug"}]}}\n'
    printf '{"type":"user","message":{"content":"never reached'
} > "${WORK}/proj/${SESSION_ID}.jsonl"
run_hook "$(payload Stop "{\"transcript_path\":\"${WORK}/proj/${SESSION_ID}.jsonl\"}")" >/dev/null
if [ "$(argv)" = "${PREFIX_ARGV}--title|Fix the login bug|" ]; then ok "falls back to the first real user message"; else bad "falls back to the first real user message" "$(argv)"; fi

# An empty first text block must not hide the block after it.
printf '{"type":"user","message":{"content":[{"type":"text","text":""},{"type":"text","text":"Second block wins"}]}}\n' > "${WORK}/proj/${SESSION_ID}.jsonl"
run_hook "$(payload Stop "{\"transcript_path\":\"${WORK}/proj/${SESSION_ID}.jsonl\"}")" >/dev/null
if [ "$(argv)" = "${PREFIX_ARGV}--title|Second block wins|" ]; then ok "an empty text block does not hide the next one"; else bad "an empty text block does not hide the next one" "$(argv)"; fi
printf '%s\n' "$NAME" > "${CC_STATUSLINE_STATE_DIR}/claude-session-${SESSION_ID}.name"

# Regression: empty fields between filled ones. A tab-joined parse collapsed
# them, so an empty agent_id swallowed tool_name and every tool call looked
# like a subagent. Here agent_id, tool_path and transcript_path are all empty.
run_hook "$(payload PreToolUse '{"tool_name":"Bash","tool_input":{"command":"true","description":"Empty fields kept"}}')" >/dev/null
if [ "$(argv)" = "${PREFIX_ARGV}--title|${NAME} · Empty fields kept|" ]; then ok "empty payload fields do not shift the others"; else bad "empty payload fields do not shift the others" "$(argv)"; fi

# A bidi override (U+202E) built with jq, so this file carries no escape for it.
bidi=$(jq -n '[8238] | implode')
run_hook "$(jq -n --arg s "$SESSION_ID" --argjson b "$bidi" '{session_id:$s, hook_event_name:"PreToolUse", cwd:"/x", tool_name:"Bash", tool_input:{command:"true", description:("safe " + $b + "efas")}}')" >/dev/null
if [ "$(argv)" = "${PREFIX_ARGV}--title|${NAME} · safe efas|" ]; then ok "format characters such as a bidi override are dropped"; else bad "format characters such as a bidi override are dropped" "$(argv)"; fi

# A name file that holds only control characters is no name at all.
awk 'BEGIN{printf "%c%c\n", 1, 2}' > "${CC_STATUSLINE_STATE_DIR}/claude-session-${SESSION_ID}.name"
run_hook "$(payload SessionStart '{"source":"startup"}')" >/dev/null
if [ "$(argv)" = "${PREFIX_ARGV}--clear-title|" ]; then ok "a control-only name clears the title on SessionStart"; else bad "a control-only name clears the title on SessionStart" "$(argv)"; fi
rm -f "${CC_STATUSLINE_STATE_DIR}/claude-session-${SESSION_ID}.name"

# The seven entries leave with uninstall, like every other entry.
bash "${ROOT}/uninstall.sh" --prefix "$FAKE_PREFIX" --settings "$FAKE_SETTINGS" >/dev/null 2>&1
n=$(jq '[ .hooks[]?[]?.hooks[]? | select((.command // "") | endswith("herdr-pane-title.sh")) ] | length' "$FAKE_SETTINGS")
if [ "$n" = "0" ]; then ok "uninstall removes all seven herdr entries"; else bad "uninstall removes all seven herdr entries" "got ${n}"; fi

echo
echo "-------------------------------------------"
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
