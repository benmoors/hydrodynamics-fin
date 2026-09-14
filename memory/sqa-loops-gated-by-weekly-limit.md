---
name: sqa-loops-gated-by-weekly-limit
description: "Full SQA loops are expensive enough to be gated by Ben's weekly usage limit — schedule them, never launch one unprompted"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: d5967321-a0bb-497f-92ee-8931c1c5ab49
  modified: 2026-08-29T19:27:11.851Z
---

A full SQA loop (`sqa-lead` → specialists → `code-reviewer`, 3 rounds) is large enough that Ben
cannot always afford one — on 2026-08-29 he deferred WP3 Step 4 to Monday 2026-08-31 purely because
the SQA pass would not fit that week's usage limit.

**Why:** `CLAUDE.md` § 4 mandates an SQA pass over any new `.ps1` touching SWD, so the gate is not
optional — which makes *when* it runs a scheduling decision rather than an implementation detail. A
loop launched at the wrong moment burns the budget that the mandatory gate needs.

**How to apply:** when planning work that will trigger an SQA loop, call out the cost explicitly and
put the loop in its own stage with its own date, rather than folding it into a larger step. Say which
stage carries "the whole token cost". Cheap stages (read-only probing, running an existing script,
document work) should be schedulable independently so they are not blocked behind the expensive one.
Related: [[stage-plans-for-multiday-work]].
