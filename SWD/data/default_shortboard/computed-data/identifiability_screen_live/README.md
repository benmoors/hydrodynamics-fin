# 📘 Identifiability screen with single-attitude live-solver forces

> **Provisional, pending my review.** Both choices below were made by fixed rules, not by me.
>
> - **Attitude: pos_y 0, pos_x 0.450 (drift 0), converged from 2 to 10 m/s.** Rule: the widest continuous converged
>   speed range, then the smallest |pos_y|, then the pos_x nearest the median converged pos_x (0.30). It tied on width
>   with pos_x 0.467 and won on the last step.
> - **Starting speed: V0 = 8.3 m/s.** Rule: on a 0.1 m/s grid, keep each V0 whose ±20 % copies are also in range, then
>   take the one whose 10.055 s baseline run stays in range longest, with ties going to the largest change in V. 39
>   values stay in range for the whole run; 8.3 m/s falls furthest, to 7.05 m/s.

---

## 1. What this is

This is a feasibility screen only. It asks whether an inverse fit could recover a friction multiplier `k` from
~15 Hz along-path acceleration when the forces come from one board attitude whose lift SWD's live solver held at the
weight. **It is not the project's forward model.** Don't reuse it as one or describe it as one.

It repeats the first screen (`../identifiability_screen/`) with forces at their physical scale. That screen took its
forces from `trajectory.py`'s `load_polar()`, which sums 7–12 scan positions per roll case (`AI-USE.md` § 5, E133).
This one uses a single attitude from `SWD/data/live_solver/default_shortboard/converged/`, at slope 0 and drift 0.
Before choosing, it drops the 11 of 169 reads whose friction, planing and rail drag do not add up to the total within
1 %.

The run is straight, at that one attitude, with no roll schedule:

    D(V)    = k · friction(V) + planing(V) + rail(V)      (PCHIP in speed, never extrapolated)
    m dV/dt = m g sin 10° − D(V)                           (m = 802.21 N / g)

Only the along-path acceleration is compared. Lift is held at the weight, so the vertical acceleration is zero, and
the sideways one, g·tan φ, does not depend on friction. The noise bounds are the first screen's x-axis values: 0.509
m/s² (upper) and 0.0283 m/s² (lower).

---

## 2. Files

| File | What it holds |
|---|---|
| `forces_used.csv` | The chosen attitude's live-solver rows, 2–10 m/s |
| `attitude_candidates.csv` | The top 5 attitudes by the rule: speed range, end forces, and the speeds where drag equals the slope's weight component |
| `v0_search.csv` | Every V0 on the grid: whether it qualifies, how long its run stays in range, and its change in speed |
| `delta_a.csv` | Shifted run minus baseline, along-path acceleration, at mmc1's sample times |
| `summary.csv` | Rows dropped, the choices, σ, how far each run got, the rtol check, and the step 7 comparison |
| `monte_carlo_fits.csv` | Every fit: draw, set, fitted k and V0, converged, at a bound, guard hits |
| `monte_carlo_summary.csv` | The Monte Carlo statistics, beside the first screen's |
| `speed_runs.png`, `delta_a_x.png`, `overlay_x.png`, `fitted_k_hist.png` | The plots |

---

## 3. Regenerating

    python SWD/model/identifiability_screen_live.py              # about 7 minutes
    python -m pytest tests/test_identifiability_screen_live.py

The script prints every number, the assumptions below, and the readings it took where the brief left a choice open.
This README is written by hand and is not regenerated.

---

## 4. Assumptions

- One attitude for the whole run. The live solver's trim and attitude are not varied with speed.
- A path-frame model compared against board-frame IMU noise.
- mmc1's board, surfer and wave differ from `default_shortboard` with an 80 kg surfer.
- The noise σ bounds are carried over from the first screen.

---

## 🤖 AI Acknowledgment

**What AI was used.** Claude Opus 5.5 via Claude Code 2.1.310 (Anthropic), 24 October 2026.

**How AI was used.** AI wrote the screen, its tests and this README, and ran it. The question, the settings, the
selection rules, the σ bounds and the 60-minute cap on the Monte Carlo were mine (`AI-USE.md` § 4). The attitude and
starting speed those rules pick are recorded in `AI-USE.md` § 2 as defaults pending my review.

**Human oversight and responsibility.** The tests check known answers: the decomposition filter, the interpolant at
its own grid points, a power-law drag with a closed-form speed, and recovery of the planted multiplier from
noise-free data. The full record is in `AI-USE.md` §§ 2, 4 and 5.

**Errors the AI made.** `trajectory.py`'s `load_polar()`, written with AI on 2026-09-01, sums 7–12 scan positions per
roll case, and the first screen inherited the inflated forces (E133). This screen exists because of that error, which is
not fixed here.
