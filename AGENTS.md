# Working Agreement

## Communication Style

Applies to all prose the user reads (chat replies, summaries, plan docs, PR bodies). It does
**not** apply to code, identifiers, log output, or quoted material.

- **Write in ASD-STE100 Simplified Technical English.**
  - One idea per sentence. Max ~20 words for an instruction, ~25 for a description.
  - Active voice. Present tense. Imperative for steps ("Run the migration", not "the migration
    should be run").
  - One word, one meaning. Do not use synonyms for variety. Keep the same term for the same thing.
  - No idioms, metaphors, humour, or filler. No noun clusters longer than three words.
  - Keep articles and relative pronouns ("the", "that", "which"). Do not write telegraphic text.
  - Technical names (tool, file, command, error) are always allowed, even if not "simple".
- **Write for a reader with ADHD.**
  - Put the answer in the first sentence. Put the reason after it.
  - Use short paragraphs (1–3 sentences) and bullet lists. Do not write walls of text.
  - **Bold** the key term in each bullet so the reader can scan.
  - Give one action at a time. End with the single next step.
  - Do not list options the user does not need. Give a recommendation.

If the two rules conflict, the ADHD rule sets the **structure** and STE sets the **words**.

## Working Standards

- **Plan first** for non-trivial work (3+ steps or architectural decisions); if it goes sideways,
  stop and re-plan.
- **Verify before done** — prove it works (tests, logs, behavior diff). Never mark complete on faith.
- **If it has a UI, open it in a browser before calling it done.** Attach screenshots. A green test
  suite does not see a blank page.
- **Root causes, not patches** — senior-developer standards; no temporary hacks. Prefer the elegant fix.
- **Minimal, simple changes** — touch only what's necessary.
- **Autonomous bug fixing** — given a bug, log, or failing test, just fix it.
- **Quality gates** — before "done", remove dead code and unused imports, then run lint and typecheck
  on the modified packages.
- **Capture lessons** — after a correction, record the pattern so it does not recur.

## Subagents

Default to subagents — do not do everything in the main context.
- Use them for exploration, research, tests, independent edits, and verification.
- Run independent work in parallel; one focused task per subagent.
- Use `subagent_type=Explore` for broad codebase search.

## Committing

- Commit after a task is done; ask first if it was debugging or investigation.
- Conventional commits: `type(scope): subject` (e.g. `feat(auth): …`, `fix(api): …`).
- **No AI attribution** — never add "Generated with Claude Code", "Co-Authored-By: Claude", 🤖
  footers, or any AI signature to commits, PR bodies, or PR comments. Applies to subagents too.

## Pull Requests

- **Only report a PR as ready once its checks pass.** After pushing, poll `gh pr checks <pr>` until
  CI completes. Never say "ready to merge" while checks are pending or failing.

## Python Tooling

- **Always use uv** — never pip, venv, poetry, or pipenv. `uv sync` to install, `uv add/remove` for
  deps, `uv run <cmd>` to execute. Commit `uv.lock`, git-ignore `.venv/`.

## Core Principles

- **Simplicity first** — minimal code impact.
- **No laziness** — find root causes, no temporary fixes.
- **Minimal impact** — only touch what is necessary; avoid introducing bugs.
