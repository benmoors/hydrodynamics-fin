---
type: worklist
order: 2
item: "2"
status: failed
effort: done
blocked_by: "—"
plan: SWD/docs/plans/WP3-STEP-0-3-verification-scan.md
---

# 2 — WP3 Steps 0–3: verification scan

| # | Item | Plan file | Effort | Blocked by | Status |
|---|---|---|---|---|---|
| 2 | **WP3 Steps 0–3** — verification scan | `WP3-STEP-0-3-verification-scan.md` | done | — | ❌ **RAN 2026-08-31, FAILED its gate** — see below |

**Links:** [plan](../plans/WP3-STEP-0-3-verification-scan.md) · [LIVE-RUN-FINDINGS.md](../../tools/phase2/LIVE-RUN-FINDINGS.md) · [SCAN-FLOW.md](../../tools/phase2/SCAN-FLOW.md) · [worklist](worklist.base) · "§ 5" below is CLAUDE.md § 5, now `.claude/rules/swd-technical-facts.md`

### ⚠️ Item 2 ran on 2026-08-31 and FAILED its gate — read before touching WP3

The automation worked; the experiment did not. Full record in
`SWD/tools/phase2/LIVE-RUN-FINDINGS.md`, dialog captures in `SWD/tools/phase2/SCAN-FLOW.md`.

- **`flow ms` does not drive the hydroscan.** The box read `10` when the scan started and all **53**
  new operating points recovered **20.0391 m/s**. *(2026-09-01: that reading was never a speed — it is
  `20500/1023`, i.e. a ρ = 1025 scan divided by an assumed 1023. The flow speed was **20.000 m/s**
  throughout, which strengthens rather than weakens this conclusion. See § 5.)* The stage plan's own rule applies: *"the parameter
  path silently did nothing and Steps 4–7 do not start."*
- **The plan's km/h premise was also wrong.** There is no `NumericUpDownScanSpeed*kmh` control; the
  live box is `flow ms`, metres per second. `ConvertTo-Kmh` must not be used on it. Setting the
  planned `36` would have asked for 36 m/s ≈ 130 km/h.
- **The copy branch resets board physics.** Scanning a protected original makes SWD save and load a
  copy, and the copy came back with `turn_radius_m` **22.806 → 100000** and setting **10 → 20**. The
  board was chosen *for* its unique 22.8 m radius, so the run gained neither a new speed nor a new
  radius. Re-read parameters after any copy; never assume they survived.
- **Strongest lead: `<no Wave>`.** No wave has ever been loaded in any session. If HydroScan takes
  flow from a wave definition that would explain a fixed ~20 m/s. Identify the control by reading it
  before scanning again — each scan costs ~12 min and writes into the library.
- **Dataset did grow**: 667 → **720** operating points, 27 → **28** boards, 143 → **154** reports,
  0 parse failures. A new hull at the existing speed.
- **The "2.7× faster" cost re-base is WITHDRAWN as invalid.** Both the 61 s and 163 s per-angle
  figures were measured at ~20 m/s, so the difference is board geometry, not speed. The only true
  low-speed datum points the other way: with a wave loaded (6.59 m/s) **not one of 11 angles
  completed in 11 minutes**, SWD computing throughout — the board is at or below planing threshold
  and the solver struggles. **There is no validated cost model for a low-speed batch.**
