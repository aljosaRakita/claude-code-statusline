# claude-code-statusline

A two-row status line for [Claude Code](https://claude.ai/code), plus the hooks that feed it.

```
Statusline Packaging │ ██████░░░░░░░░░ 42.5% │ in:1.2M out:8.9k │ Opus 5 │ high
wt:fd-017 │ master* │ projects/demo-app │ $3.46 │ 1h31m │ +128-47 │ 🕐 08:19:06
```

It joins both rows onto one line when the terminal is wide enough, and splits them when it is not.

## What each field means

**Row 1**

| Field | Meaning |
| --- | --- |
| Session name | What this session is about. Claude sets it. See [Session names](#session-names). |
| Context bar | Context window used. 15 blocks. Green, yellow at 60%, red at 80%. |
| `in:` / `out:` | Total input and output tokens, as `12.3k` or `1.5M`. |
| Model | The model display name. |
| Effort | Reasoning effort. Green for high, yellow for medium, red for low. |

**Row 2**

| Field | Meaning |
| --- | --- |
| `wt:` | Worktree name, when the session runs in a git worktree. |
| Branch | Current branch, with `*` when the tree is dirty. |
| Path | Last two components of the working directory. |
| `$` | Session cost so far. |
| Duration | Wall-clock time in the session. |
| `+/-` | Lines added and removed. |
| 🕐 | Time of the last tool call. |

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

1. Claude writes the name to `claude-session-pending.name` in the state directory.
2. On its next draw, the status line **promotes** that file to `claude-session-<session_id>.name`
   and writes the id back to `claude-session-id`.
3. Later updates can go straight to the real file.

When `CLAUDE_CODE_SSE_PORT` is set, the pending and id files are keyed by that port, so two live
sessions cannot pick up each other's names.

The `session-name-check.sh` hook runs on every prompt. It asks Claude to set a name when none
exists, and to reconsider one older than 10 minutes. It stays quiet when a name is already
pending.

If no name file exists, the status line falls back to the session summary in
`sessions-index.json`, then to the first user message in the transcript.

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

45 assertions. They drive the real scripts with a captured status payload and check the
behaviour that matters: every field renders, a pending name is promoted and shown, the timestamp
a hook writes is the timestamp the renderer reads, `Stop` emits valid `systemMessage` JSON, and
installing twice leaves settings valid with no duplicate entries.

On Linux:

```bash
docker run --rm -v "$PWD":/w -w /w debian:stable-slim \
  sh -c 'apt-get update -qq && apt-get install -y -qq bash jq git && bash tests/render.sh'
```

The Linux run is not ceremony. It caught a real bug: the context bar was built with
`tr ' ' '█'`, which is byte-oriented in GNU coreutils and emitted broken UTF-8 on Linux while
looking perfect on macOS.

**What the tests do not prove:** that Claude Code dispatches the hooks correctly on your
machine. They prove the scripts, driven with recorded payloads. Windows and WSL are untested.

## License

MIT. See [LICENSE](LICENSE).
