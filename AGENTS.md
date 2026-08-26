# Working Agreement

## Communication Style

Applies to all prose the user reads (chat replies, summaries, plan docs, PR bodies). It does
**not** apply to code, identifiers, log output, or quoted material.

- **Write in ASD-STE100 Simplified Technical English.**
  - One idea per sentence. Max ~20 words for an instruction, ~25 for a description.
  - Active voice. Present tense. Imperative for steps ("Run the migration", not "the migration
    should be run").
  - One word, one meaning. Do not use synonyms for variety. Keep the same term for the same thing.
  - No idioms, metaphors,n clusters longer thanthree words.
  - Keep articles and relat", "which"). Do not write telegraphic text.
  - Technical names (toole always allowed, even ifnot "simple".
- **Write for a reader wi
  - Put the answer in the first sentence. Put the reason after it.
  - Use short paragraphs  lists. Do not write wallsof text.
  - **Bold** the key termder can scan.
  - Give one action at a time. End with the single next step.
  - Do not list options te a recommendation.

If the two rules conflict*structure** and STE setsthe **words**.                                                               
## Working Standards                                                         
- **Plan first** for non-trivial work (3+ steps or architectural decisions); if it goes sideways,
  stop and re-plan.
- **Verify before done** ogs, behavior diff). Nevermark complete on faith.
- **If it has a UI, open ling it done.** Attachscreenshots. A green test                                                   suite does not see a bl
- **Root causes, not patches** — senior-developer standards; no temporary hacks. Prefer the elegant
- **Minimal, simple changes** — touch only what's necessary.                   - **Autonomous bug fixingfailing test, just fix it.
- **Quality gates** — before "done", remove dead code and unused imports, then run lint and typecheck
  on the modified packages.
- **Capture lessons** — athe pattern so it does notrecur.

## Subagents

Default to subagents — do not do everything in the main context.
- Use them for explorationdent edits, andverification.
- Run independent work ink per subagent.
- Use `subagent_type=Explore` for broad codebase search.

## Committing

- Commit after a task is done; ask first if it was debugging or investigation.
- Conventional commits: `. `feat(auth): …`,`fix(api): …`).
- **No AI attribution** — Claude Code","Co-Authored-By: Claude", 🤖
  footers, or any AI signs, or PR comments. Appliesto subagents too.

## Pull Requests

- **Only report a PR as ready once its checks pass.** After pushing, poll `gh
pr checks <pr>` until
  CI completes. Never say "ready to merge" while checks are pending or
failing.

## Python Tooling

- **Always use uv** — nevipenv. `uv sync` toinstall, `uv add/remove` for
  deps, `uv run <cmd>` to, git-ignore `.venv/`.

## Core Principles

- **Simplicity first** —
- **No laziness** — find root causes, no temporary fixes.
- **Minimal impact** — on; avoid introducing bugs.
