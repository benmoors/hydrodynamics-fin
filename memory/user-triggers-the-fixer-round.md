---
name: user-triggers-the-fixer-round
description: "WITHDRAWN 2026-09-02 — run the full QA loop including the fixer, per global CLAUDE.md; do not stop at the SQA verdict."
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 50a19d62-c6f0-40fb-9961-88890f98501e
  modified: 2026-09-02T05:02:48.083Z
---

**This memory previously said the opposite, and that was wrong. Run the FULL loop.**

Earlier on 2026-09-02 the user said *"do not automatically run code-reviewer, I will run that
later."* Within the same session they reversed it: *"No do the full loop"* / *"With the fixer"*
/ *"Until loop is finished as in global CLAUDE.md."*

So the operative rule is the sqa-loop skill as written: `sqa-lead` → show the summary
as FYI (**not** a gate) → `code-reviewer` with the findings handed over **verbatim** → a
**fresh** `sqa-lead` verifies. Cap ~3 rounds. Gate on the `VERDICT:` line reaching
`Critical=0 | Warning=0`. No approval gate on fixes at any severity; the two carve-outs stand
(findings the reviewer can rebut with evidence, and changes to observable behaviour), plus
security fixes needing sign-off.

**Why the correction matters:** stopping at the verdict leaves the loop half-run, and in this
project a non-clean verdict blocks real work downstream — the 2b.5/2b.6 live run cannot start
until the gate is met (`CLAUDE.md` § 4 requires an SQA pass over any new `.ps1` before it
touches the EUR 210 installation). Holding the fixer back does not protect anything; it just
parks the blocker.

**How to apply:** run the loop to completion or to its cap, then report the routing decision,
the verdict progression, the changelog, and the backup path. Do not ask permission between
rounds. Still do not launch a loop *unprompted* — see [[sqa-loops-gated-by-weekly-limit]].
