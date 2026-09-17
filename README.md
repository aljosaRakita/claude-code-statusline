# claude-code-statusline

A one-row status line for [Claude Code](https://claude.ai/code), plus the hooks that feed it.

```
Statusline Packaging 42% │ Opus 5 high │ fd-017 master* projects/demo-app │ $3.46 1h31m +128-47 │ 08:19:06
```

The row always stays on one line. When the terminal is too narrow, the renderer drops segments
in this order until the row fits: clock, lines, duration, path, worktree, cost, session name.
The percentage, model, effort and branch always stay. At 80 columns the example becomes:

```
Statusline Packaging 42% │ Opus 5 high │ fd-017 master* │ $3.46
```

## What each field means

| Field | Meaning |
| --- | --- |
| Session name | What this session is about. Claude sets it. See [Session names](#session-names). |
| Percentage | Context window used. Grey below 30%, green from 30%, yellow from 50%, orange from 75%, red from 80%, bold red from 90%. |
| Model | The model display name. |
| Effort | Reasoning effort. Green for high, yellow for medium, red for low. |
| Worktree | Worktree name, when the session runs in a git worktree. |
| Branch | Current branch, with `*` when the tree is dirty. Cut to 24 characters. |
| Path | Last two components of the working directory. |
| `$` | Session cost so far. |
| Duration | Wall-clock time in the session. |
| `+/-` | Lines added and removed. |
| Clock | Time of the last tool call. |

Fields that have no value are left out, separators and all.

## The chat stamp

The `Stop` hook also prints a line into the transcript at the end of each turn:

```
🕐 Tue 2026-08-25 08:19:06
```

This is the part people do not expect, and it is arguably more useful than the status line
itself. It gives you a visible timeline in your scrollback, and it is the only way the model
learns the current date and time in the middle of a session. Set `CC_STATUSLINE_CHAT_STAMP=0`
to keep the clock in the bar and drop the chat line.

## Install

Requires **`jq`**. `git` is optional and only powers the branch field.

```bash
git clone https://github.com/aljosaRakita/claude-code-statusline.git
cd claude-code-statusline
./install.sh
```

Then restart Claude Code, or start a new session.

The installer:

- copies the scripts to `~/.claude/statusline/`, so your existing hooks are never overwritten,
- backs up `settings.json` before writing,
- refuses to write invalid JSON,
- is safe to run twice. A second run replaces its own entries instead of duplicating them.

Options:

```bash
./install.sh --dry-run              # print the merged settings, change nothing
./install.sh --with-notifications   # also enable desktop notifications
./install.sh --with-herdr           # also name herdr panes after the session
./install.sh --prefix ~/somewhere   # install elsewhere
./install.sh --settings /path/to/settings.json
```

If `settings.json` already points at a status line outside the install prefix, the installer
says so and leaves those entries alone. Remove them by hand if you are replacing an older setup.

### Manual install

Copy `statusline-command.sh`, `lib/` and `hooks/` to `~/.claude/statusline/`, then merge
[`settings/snippet.json`](settings/snippet.json) into your `~/.claude/settings.json`.

## Uninstall

```bash
./uninstall.sh            # removes only its own entries, backs up settings first
./uninstall.sh --dry-run
```

## Session names

Claude names its own sessions, and the mechanism is worth understanding before you change it.

**Claude cannot see its own session id.** So it cannot write
`claude-session-<id>.name` directly. Instead:

1. The `session-name-check.sh` hook prints the path to write to:
   `claude-session-pending-<session_id>.name`, in the state directory.
2. Claude writes the name there.
3. On its next draw, the status line **promotes** that file to
   `claude-session-<session_id>.name`.

**The pending path carries the session id, so never carry one across sessions.** Within a session
the path is stable, and reusing it is how a rename works — the hook is quiet while a name is
fresh, so nothing hands the path over on demand. A path remembered from an *earlier* session is a
wrong path.

Two sessions that ran at once used to share one `claude-session-pending.name`, and whichever
renderer drew first promoted the name, whoever wrote it. A leftover unkeyed file is therefore never
promoted, only aged out: a name pending when you upgrade is dropped, and the hook asks for it again
on the next prompt.

**Every draw also sweeps pending files older than an hour**, from every session, not just its own.
Promotion normally happens on the next draw a second later, so an hour-old pending file belongs to
a session that is gone. Nothing sweeps a promoted `claude-session-<id>.name`.

The hook runs on every prompt. It asks Claude to set a name when none exists, and to reconsider
one older than 10 minutes. Both messages name the path. It stays quiet when a name is already
pending.

If no name file exists, the status line falls back to the session summary in
`sessions-index.json`, then to the first user message in the transcript.

## herdr pane titles

Off by default. Enable with `./install.sh --with-herdr`. For a manual install, append the
entries in [`settings/snippet-herdr.json`](settings/snippet-herdr.json) to the matching arrays
in your `settings.json`; do not replace the arrays.

[herdr](https://herdr.dev) is a terminal multiplexer for coding agents. It shows each Claude
Code pane with the terminal title Claude Code set from the first prompt, which goes stale as
the session moves on. With this hook the pane title follows the session name instead, and
shows what the tool call is doing while it runs:

| Event | Pane title |
| --- | --- |
| Session start | `Packaging Run` |
| Prompt submitted | `Packaging Run · thinking` |
| Tool call starts | `Packaging Run · editing install.sh` |
| Tool call ends | `Packaging Run · thinking` |
| Turn finished | `Packaging Run` |
| Session ended | cleared |

The hook calls `herdr pane report-metadata`, the display-only API herdr documents for user
hooks that run beside its own Claude integration. Lifecycle state and session restore stay
with the integration. Outside herdr, for subagents, or when herdr fails, the hook exits
silently. Each entry carries a 5-second timeout, and the hook adds its own 3-second limit
where a `timeout` binary exists; a herdr server that hangs while its socket file still exists
can cost up to 5 seconds per event on a system without one.

The name comes from the promoted name file, then the `sessions-index.json` summary, then the
first user message, the same chain the status line uses. Titles are one line, stripped of
control characters, and cut at 80 characters, herdr's own cap; a very long name leaves no room
for the activity.

What reaches herdr: the session name, the tool name, the basename of a file path, and Claude's
short description of a Bash command. The command line itself never does. herdr keeps titles in
server memory and drops them when the pane closes.

## The state directory

Everything shared between the hooks and the renderer lives in one directory, resolved by
[`lib/paths.sh`](lib/paths.sh):

1. `$CC_STATUSLINE_STATE_DIR`, if set
2. `/private/tmp/claude-<uid>` on macOS
3. `/tmp/claude-<uid>` elsewhere

**One directory, resolved in one place, is the whole point.** The status line reads files the
hooks write. When the two sides disagreed about the path, the session name and the clock stayed
empty and nothing reported an error.

## Configuration

| Variable | Default | Effect |
| --- | --- | --- |
| `CC_STATUSLINE_STATE_DIR` | per-uid tmp dir | Where the shared state files live. |
| `CC_STATUSLINE_CHAT_STAMP` | `1` | `0` drops the date line from the transcript. |
| `CC_STATUSLINE_STALE_MINUTES` | `10` | How old a session name gets before the nag. |
| `CC_STATUSLINE_NO_TITLE` | `0` | `1` stops the script setting the terminal title. |
| `CC_NOTIFY_SENDER` | unset | macOS bundle id to borrow an icon from, e.g. `com.microsoft.VSCode`. |

## Notifications

Off by default, since the sounds are a matter of taste. Enable with
`./install.sh --with-notifications`.

- **macOS** — `terminal-notifier` when installed, otherwise `osascript`.
- **Linux** — `notify-send` when installed.
- **Anything else** — silent success. A missing notifier never fails a hook.

## Tests

```bash
bash tests/render.sh
```

124 assertions. They drive the real scripts with a captured status payload and check the
behaviour that matters: every field renders, each percentage band takes its colour, the row
fits one line at 400, 75, 60 and 40 columns, a pending name is promoted and shown, the timestamp
a hook writes is the timestamp the renderer reads, `Stop` emits valid `systemMessage` JSON,
installing twice leaves settings valid with no duplicate entries, and the installed herdr hook
sends exactly the documented arguments to a stub `herdr`, ignores subagents, and stays silent
and fast outside herdr.

On Linux:

```bash
docker run --rm -v "$PWD":/w -w /w debian:stable-slim \
  sh -c 'apt-get update -qq && apt-get install -y -qq bash jq git && bash tests/render.sh'
```

The Linux run is not ceremony. It caught a real bug: an earlier context bar was built with
`tr ' ' '█'`, which is byte-oriented in GNU coreutils and emitted broken UTF-8 on Linux while
looking perfect on macOS.

**What the tests do not prove:** that Claude Code dispatches the hooks correctly on your
machine. They prove the scripts, driven with recorded payloads. Windows and WSL are untested.

## License

MIT. See [LICENSE](LICENSE).
