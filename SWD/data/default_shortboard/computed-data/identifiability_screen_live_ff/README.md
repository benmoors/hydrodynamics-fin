# 📘 Gate B rerun: the live-solver screen with F_f(V) as the friction

> **No verdict.** This is the feasibility screen in `../identifiability_screen_live/` with one change: the friction is
> F_f(V) from `src/friction/friction_force.py`, not SWD's `friction_n`. The attitude (pos_y 0, pos_x 0.45, slope 0,
> drift 0) and the starting speed V0 = 8.3 m/s are held at the original run's values, so friction is the only change.
>
> **PLANTED (1.10) and FRICTION_SHIFT (0.10) now scale F_f, not SWD's `friction_n`.**

---

## 1. What this is

F_f splits the wetted length L at SWD's transition point and puts each part on its own law:

    F_f(V) = ½ρV²·A(V)·[(x_tr/L)·C_lam + (1 − x_tr/L)·0.031/Re_L^(1/7)],   x_tr = min(5×10⁵·ν/V, L)

C_lam is the Blasius average coefficient from the RK4 shooting, at the laminar run's Reynolds number. The turbulent
part uses SWD's closure. A and L are the live solver's wetted area and length at the held attitude: 0.631094 m² and
1.530 m, the same at every speed. At this attitude F_f is 0.985–0.989 of SWD's own `friction_n` from 2 to 10 m/s.

The screen file, `src/swd_model/identifiability_screen_live.py`, is not edited. `src/friction/rerun_live_screen_ff.py`
imports it and swaps out three of its names before running it. At the held attitude, `friction_n` becomes F_f at the
same 1 m/s speeds, so the screen's own PCHIP and drag sum work unchanged; the decomposition check runs first, on SWD's
friction, so the same 158 rows are kept and the same 11 dropped. The attitude and V0 are read from the original run's
`summary.csv` and held. The outputs come here, and the original folder, hashed before and after the run, is unchanged.

Everything else is the original run's: the noise bounds, the sample times, the settings and the 60-minute Monte Carlo
cap.

---

## 2. Results beside the original

Monte Carlo spread of the fitted multiplier k (true k = 1.10), along-path acceleration only, seed 20261024. Set (a)
fits k with V0 known; set (b) fits k and V0 together.

| Run | σ bound | Set | sd k, SWD `friction_n` | sd k, F_f | Change | Within ±band, SWD | Within ±band, F_f |
|---|---|---|---:|---:|---:|---:|---:|
| 3 s | lower | (a) | 0.007223 | 0.007279 | +0.8 % | 1 | 1 |
| 3 s | lower | (b) | 0.2836 | 0.2881 | +1.6 % | 0.185 | 0.185 |
| 3 s | upper | (a) | 0.1304 | 0.1314 | +0.8 % | 0.593 | 0.588 |
| 3 s | upper | (b) | 0.5326 | 0.5336 | +0.2 % | 0.155 | 0.147 |
| 10.055 s | lower | (a) | 0.005883 | 0.005923 | +0.7 % | 1 | 1 |
| 10.055 s | lower | (b) | 0.1125 | 0.1188 | +5.6 % | 0.748 | 0.728 |
| 10.055 s | upper | (a) | 0.106 | 0.1067 | +0.7 % | 0.684 | 0.681 |
| 10.055 s | upper | (b) | 0.3886 | 0.3944 | +1.5 % | 0.0625 | 0.07 |

Every spread is 0.2–5.6 % wider with F_f, and no within-band fraction moves by more than 2 percentage points. All
eight combinations settled within 5 %, and the Monte Carlo used 747 s of its 3600 s cap.

The peak friction signal, max|Δa_x| for k ± 10 %, drops from 0.0900 to 0.0889 m/s² (at t = 0 in both runs). That is
about the 1.2 % by which F_f sits below SWD's friction at 8.3 m/s. The starting-speed shifts move by about 1 % as well
(V0 + 20 %: 0.4157 to 0.4119 m/s²; V0 − 20 %: 0.2653 to 0.2620 m/s²), because the base drag is lower.

---

## 3. Files

These are the same files as the original. Three of them put F_f beside quantities that are still SWD's.

| File | What it holds |
|---|---|
| `forces_used.csv` | The held attitude's rows, 2–10 m/s. `friction_n` is F_f, 0.07 N (2 m/s) to 1.07 N (10 m/s) below SWD's own. `drag_total_n` is still SWD's, so the components miss it by 0.002–1.4 N (SWD's own components missed it by 0.9–1.4 N). The runs never use `drag_total_n` |
| `attitude_candidates.csv` | The held attitude only. Its friction columns are F_f; `v_eq_swd_total_k1` still comes from SWD's total drag |
| `v0_search.csv` | The screen's V0 rule under F_f. It would pick 4.4 m/s; V0 is held at 8.3 m/s |
| `delta_a.csv`, `summary.csv`, `monte_carlo_fits.csv`, `monte_carlo_summary.csv` | As in the original, with F_f as the friction. `monte_carlo_summary.csv` also carries the first screen's rows |
| `speed_runs.png`, `delta_a_x.png`, `overlay_x.png`, `fitted_k_hist.png` | The plots |

---

## 4. Regenerating

    python -m src.friction.rerun_live_screen_ff
    python -m pytest tests/test_rerun_live_screen_ff.py tests/test_friction_force.py

The script prints every number, the screen's assumptions, and the table of SWD's friction against F_f at the end.
This README is written by hand and is not regenerated.

---

## 5. Assumptions

The original screen's four assumptions hold here too. F_f adds three:

- A flat plate, zero pressure gradient and a smooth wall.
- A and L are constant in speed at a fixed attitude, so the wetted area does not shrink with speed. All of F_f's
  speed dependence comes from the friction law.
- The friction is the screen's PCHIP of F_f at the 1 m/s speeds, as SWD's `friction_n` was. Between those speeds it
  differs from F_f by up to 0.34 % (at 2.55 m/s).

---

## 🤖 AI Acknowledgment

**What AI was used.** Claude Opus 5.5 via Claude Code 2.1.311 (Anthropic), 27 October 2026. Antigravity CLI (Gemini 4
Argon) and Devin CLI (SWE-1.7 Max) reviewed the rerun script and F_f.

**How AI was used.** AI wrote `rerun_live_screen_ff.py`, its tests and this README, and ran the rerun. Choosing this
screen as Gate B, holding the attitude and V0, the design of F_f and what the output states were mine (`AI-USE.md`
§ 4).

**Human oversight and responsibility.** The tests check that only the friction at the held attitude changes, that
the rows and the geometry come from the CSV passed in, and that the attitude and V0 are held. The original outputs
were hashed before and after the run and are unchanged. The full record is in `AI-USE.md` §§ 2, 4 and 5.

**Errors the AI made.** The script's note on `forces_used.csv` first gave F_f's difference from SWD's friction as the
components' gap from the total (E148). A review caught it, and it was corrected before this run.
