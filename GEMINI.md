# GEMINI.md — Antigravity CLI (`agy`) notes

`agy` loads **both** `AGENTS.md` and this file at the workspace root, always on. `AGENTS.md` holds
the role, commands, write scope and hard boundaries, and the audit-and-fix procedure is the
on-demand skill `.agents/skills/audit/SKILL.md`. This file carries only what is
Antigravity-specific, so nothing is paid for twice.

- **One agent, no fan-out.** Do not spawn dynamic subagents or parallel agents for an audit. The
  target is a file, folder or diff, and a single pass is cheaper and easier to reproduce.
- **Headless run** (from the repo root; Claude's `sqa-loop` launches it this way through
  `~/.claude/tools/sqa_cli_pass.py`):
  `agy -p "Use the audit skill on src/splits.py. Audit, then fix." --dangerously-skip-permissions --print-timeout 1740s`
- **Permissions:** approve reads, file edits **in `src/`, `tests/`, `SWD/tools/` and `tools/`**,
  appends to `AI-USE.md`, `py -3.14 -m pytest`, `lint_probe.py`, `Invoke-Pester`,
  `extract_prompts.py --dry-run` and read-only `git`. Refuse edits anywhere else, running SWD or a
  hydroscan driver, commit and push.
- **Global rules** in `~/.gemini/GEMINI.md` also load. Keep that file small.
- Per-file rule limit is 24 KB after `@` includes. **Do not `@`-inline** `CLAUDE.md`, `README.md`
  or `AI-USE.md`; read the one section you need instead.
