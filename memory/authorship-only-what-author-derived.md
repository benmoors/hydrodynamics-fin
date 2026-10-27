---
name: authorship-only-what-author-derived
description: "In AI-USE.md and docstrings, record as Benjamin's only what he derived or chose; anything Claude (Claude Code or a claude.ai chat) wrote out, proposed as options, or framed is recorded as Claude's, even when he confirmed it."
metadata:
  node_type: memory
  type: feedback
  originSessionId: 5af91cfa-5add-4abf-9c96-def27de2be6a
  modified: 2026-10-27T01:41:47.651Z
---

When Benjamin says "mark this derivation as my own", record as his only the pieces he derived himself. A piece
Claude Code wrote out from his constraints (e.g. phi(delta) = U*alpha*delta^2/(2*nu*beta), filled in where his
placeholders arrived blank) is recorded as "written by Claude Code from his constraints, confirmed by him",
never as 100 % his, and the docstring uses the same wording as AI-USE.md.

The same holds for decisions. When Claude, in a claude.ai chat or in Claude Code, proposed the options or the
framing (e.g. "V0 exact / fitted / measured with an uncertainty" and the bracket framing, 2026-10-27), the § 4 row
says so and records only the **choice** as his. "The wording came from Claude" is not enough.

**Why:** 2026-10-27: "Do not record the derivation as 100% mine if phi stays in the code", and, rejecting a plan
that said "wording only": "the options … and the bracket framing were proposed by Claude in a claude.ai chat on
27 Oct. The choices are mine. Record it that way, not as wording only." The AI-use record is graded (rubric
criterion 6) and he is accountable in the interview for every claim (R7).

**How to apply:** split authorship per item in AI-USE.md § 3/§ 4 and in module docstrings: who derived, who
proposed the options, who framed it, who chose. Keep the record of what Claude supplied even when it was later
dropped. A claude.ai chat counts as AI use even though its prompts are his to add to § 6.
