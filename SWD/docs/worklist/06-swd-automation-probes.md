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
| 6 | **Automation probes T1–T17** — test each observe/act/settle/safety technique on live SWD | `SWD-AUTOMATION-PROBES.md` | medium | — | ◐ Stages 1–2 done 2026-09-30 (detector works on the success path; Apply Length actuates in the background). SQA pass done 2026-10-01 (`Critical=0 | Warning=3 | Suggestion=11`; detector error paths fixed, E104). Owed: Benjamin's decisions on W7 (`Applied` semantics) and NEW-1 (capture failure), `swd_msg`/`swd_diagnose` tests unelevated, T16 lock test. **2026-10-01/02: the full input sweep ran overnight** (`swd_probe.ps1 -Probe Sweep`, 58 inputs, 230 trials, library unchanged); NEW-1 fixed under Benjamin's light-fix delegation (§ 4), W7 still his; the sweep's own SQA pass is owed. Result: wiki *SWD Input-Output Sensitivity Map*. **2026-10-05/06: live-solver Stage 1 pilot + loop test** (2,448 reads, 272 positions × 3 speeds × 3 slopes; no relaunch needed, E110; `elements.csv` rows are scan positions, E111); Stage 2 levels are Benjamin's. Result: wiki *SWD Live-Solver Pilot 2026-10-05* |

Why: two AI research reports proposed a fiddling rig. Their claims were checked against primary
sources on 2026-09-30; the untested ones are these probes. Evidence and verdicts:
`wiki/syntheses/SWD Automation Technique Register.md`.

**Links:** [plan](../plans/SWD-AUTOMATION-PROBES.md) · [worklist](worklist.base)
