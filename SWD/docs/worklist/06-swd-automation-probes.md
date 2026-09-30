---
type: worklist
order: 6
item: "6"
status: todo
effort: medium
blocked_by: "—"
plan: SWD/docs/plans/SWD-AUTOMATION-PROBES.md
---

# 6 — SWD automation probes (before the evening fiddling rig)

| # | Item | Plan file | Effort | Blocked by | Status |
|---|---|---|---|---|---|
| 6 | **Automation probes T1–T17** — test each observe/act/settle/safety technique on live SWD | `SWD-AUTOMATION-PROBES.md` | medium | — | ◐ Stages 1–2 done 2026-09-30 (detector works on the success path; Apply Length actuates in the background). SQA pass done 2026-10-01 (`Critical=0 | Warning=3 | Suggestion=11`; detector error paths fixed, E104). Owed: Benjamin's decisions on W7 (`Applied` semantics) and NEW-1 (capture failure), `swd_msg`/`swd_diagnose` tests unelevated, T16 lock test |

Why: two AI research reports proposed a fiddling rig. Their claims were checked against primary
sources on 2026-09-30; the untested ones are these probes. Evidence and verdicts:
`wiki/syntheses/SWD Automation Technique Register.md`.

**Links:** [plan](../plans/SWD-AUTOMATION-PROBES.md) · [worklist](worklist.base)
