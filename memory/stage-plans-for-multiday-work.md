---
name: stage-plans-for-multiday-work
description: "Ben wants multi-day work split into standalone stage plans in the repo, indexed in CLAUDE.md so he can ask \"what is the next thing to be done\""
metadata: 
  node_type: memory
  type: feedback
  originSessionId: d5967321-a0bb-497f-92ee-8931c1c5ab49
  modified: 2026-08-29T19:27:23.567Z
---

On 2026-08-29 Ben asked for one long plan to be split into separate stage files, each carrying its
full context, stored in the repo (`SWD/docs/plans/`) rather than `~/.claude/plans/`, with a routing
section in `CLAUDE.md` so that saying "begin Step 4" resolves to the right file and "what is the next
thing to be done" has one authoritative answer.

His words: *"I forgot what the order is of everything."*

**Why:** the work spans days and usage-limit boundaries, and session-scratch plans in
`~/.claude/plans/` have opaque auto-generated names (`coudl-you-open-up-expressive-rose.md`), no
ordering between them, and no status. Work packages went unnoticed as a result — WP1 and WP2 had been
outstanding since 2026-08-27 with nothing surfacing them.

**How to apply:** for anything spanning more than one session, write one file per stage, each naming
its own prerequisite in a callout at the top and **repeating** the shared context rather than
cross-referencing a sibling — a file that only makes sense after reading its predecessor fails at
cold resume. Keep an ordered index with a live status column in `CLAUDE.md`, and update the status as
stages complete. (Since 2026-09-14 the HYDRODYNAMICS-FIN index is one note per item in
`SWD/docs/worklist/` with `status` frontmatter, queried via `worklist.base`; CLAUDE.md § 9 points at it.) Before writing such an index, audit the existing plan files and verify on disk which
packages are actually outstanding, rather than trusting what a plan claims. Related:
[[sqa-loops-gated-by-weekly-limit]].
