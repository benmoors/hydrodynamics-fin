# Dataset coverage

Every number here is measured from the extracted CSVs, not estimated.

**Status: Phase 1 + one Phase 2 scan.** On 2026-08-28 a hydroscan was driven through the automation
for the first time, adding **11 reports** on `default_shortboard_Copy_1`. It ran at the settings
already loaded — **not** at a new speed — so it adds a 13th scanned board without touching the
binding constraint below.

## Tables

| File | Rows | Cols | Role |
|---|---:|---:|---|
| `operating_points.csv` | 667 | 19 | **training table** |
| `elements.csv` | 6,388 | 22 | spatial mesh — *not* independent samples |
| `boards.csv` | 27 | 10 | board metadata |
| `fin_polars.csv` | 680,400 | 7 | fin profile polars |

`extract_manifest.json` is the completion sentinel: it is written last, lists only tables this
run actually produced, and records every dropped column. `polar_blocks` = 1,890 / 1,890,
parse failures 0.

## The four required ML channels

| Channel | Column | dtype | Min | Max | Distinct | NaN |
|---|---|---|---:|---:|---:|---:|
| Trajectory speed (m/s) | `scan_speed_ms` | float64 | 20.0000 | 20.0391 | **2** (10 raw) | 0 |
| Roll angle (rad) | `roll_rad` | float64 | -0.3738 | 1.3684 | 666 | 0 |
| Turn radius (m) | `turn_radius_m` | float64 | 19.0782 | 100000.0000 | **9** | 0 |
| Drag force (N) | `drag_total_n` | float64 | 157.4034 | 522339.1514 | 667 | 0 |

Speed shows 10 distinct values at full float precision and **2** at 3 dp. That is float noise around
a single condition, not a second operating point — see the constraint below.

## Coverage against the target domains

| Axis | Target | Actual | Verdict |
|---|---|---|---|
| Speed | open | **one value, ~20 m/s** | ❌ no variation |
| Roll | [-π/3, π/3] = [-1.047, 1.047] | -0.374 … 1.368 | ⚠️ 643/667 in domain |
| Turn radius | varied | 9 distinct, 19.1 … 100000 m | ⚠️ thin, no negative radii |
| Drag | measured | 157.4 … 522339.2 N | ✅ complete |

## The binding constraint: (speed, radius) pairs

| Scan speed (m/s) | Turn radius (m) | Operating points |
|---:|---:|---:|
| 20.000 | 19.1 | 52 |
| 20.000 | 30.1 | 52 |
| 20.000 | 34.7 | 50 |
| 20.000 | 45.9 | 52 |
| 20.000 | 56.5 | 50 |
| 20.000 | 87.3 | 51 |
| 20.000 | 115.9 | 52 |
| 20.000 | 312.1 | 52 |
| 20.000 | 100000.0 | 155 |
| 20.039 | 100000.0 | **101** ← +50 from the 2026-08-28 scan |

**2 distinct scan speeds (1 physical), 9 radii — unchanged by the new scan.**
Row count is ample — Loeppky, Sacks & Welch (*Technometrics*, 2009) put the floor for an initial
computer experiment at roughly 10× the input dimension, about 20 for two features, against 667 here.
Coverage is the problem, not volume: with one speed, nothing trained on this can speak to speed
dependence.

## ✅ Settled 2026-08-28: turn radius is per-BOARD, permanently

This was open from the start and only a controlled scan could answer it. `global_scan` hands radius
back as an `Image` while `Create_Chart_scan_radius` takes a `Single[]`; whether that array reaches
disk decides whether radius can ever be a per-operating-point value.

**It does not.** `turn_radius_m` is constant within **13 of 13** scanned boards, including the scan
run and watched on 2026-08-28 — 50 operating points across 11 drift angles, all carrying the single
value 100000 m.

**Consequence for modelling:** radius is board metadata, not a per-point feature. Training
`(V, φ) → R` teaches board recognition and would score well while meaning nothing. The earlier
finding ("0 of 12 boards vary internally") was therefore a property of the file format, not an
artefact of a thin corpus.

## ⚠️ Provenance note on `default_shortboard_Copy_1`

**Retracted 2026-08-28, same day it was written.** An earlier version of this section asserted the
board was homothetically scaled to 2000 mm before the scan. **That is not supported.** After the scan
the length field (`WM_GETTEXT` on the live control) reads **1800**, and so does the window title. A
2000 mm title *was* observed mid-session, but the board is 1800 mm now and nothing establishes which
state the scan ran in, nor whether the difference below predates today at all.

What is measured is only that Copy_1 differs from its siblings:

| Board | Mass (kg) | Volume (L) |
|---|---:|---:|
| `default_shortboard_Copy_1` | **2.134** | **35.22** |
| `default_shortboard_Copy_2` | 1.770 | 24.86 |
| `default_shortboard_Copy_3` | 1.770 | 24.86 |

+20.6% mass, +41.7% volume against its siblings, at the **same 1800 mm length**. So it differs in
section or thickness, not length — and a 1.111× homothety, which would explain the volume, is
contradicted by the unchanged length. **The cause is unknown.** No pre-scan `boards.csv` survives to
compare against, because the data directory is regenerated in place and `SWD/` is untracked.

**The data is internally consistent** — `boards.csv` and the operating points come from the same
geometry — so nothing here is corrupt. But `default_shortboard_Copy_1` is not interchangeable with
its siblings, and the reason is not established. **To settle it, capture `boards.csv` before and
after the next scan.**

## ⚠️ `default_shortboard_Copy_2` is a geometric duplicate

Copy_2 and the already-scanned Copy_3 are identical to full float precision on mass, volume and foam
mass. Of the 27 boards there are **26 distinct geometries**. Scanning Copy_2 would add ~30 minutes of
scan time and a near-duplicate row group — pseudo-replication, not information. **Skip it in any
batch.** The other 13 unscanned boards are genuinely distinct.

## ⚠️ Data-quality artefacts you must handle before modelling

These are SWD's own values, copied faithfully. They are not extraction errors.

### 1. `Single.MaxValue` sentinels in `elements.csv`

`3.402823e+38` (.NET `Single.MaxValue`) appears in `element_width_mm`. **It does NOT reach
`operating_points.csv`** — verified zero cells above 1e+30 in the training table, because the
affected column is not summed into the operating points. If you use `elements.csv` directly, drop
rows where `abs(value) > 1e30`; left in, it moves that column's mean by ~33 orders of magnitude and
destroys any standardisation.

### 2. Negative drag coefficients in `fin_polars.csv`

12 rows of 680,400 (0.0018%) carry `cd < 0`, which is unphysical. From SWD's shipped polar tables.
Filter `cd < 0` before use.

### 3. Columns dropped at extraction

Constant-zero columns are removed rather than exported, because a field SWD never populates
deserialises to a real `0.0f` and would read as data. Dropped this run:

- `boards.csv`: `structure_mass_kg`
- `elements.csv`: `roll_surface_rad`, `max_area_m2`, `immersed_section_m2`, `dynamic_pressure_pa`,
  `cv_savitsky`, `lambda_savitsky`, `cl0_savitsky`, `cl0_theoretical`, `boundary_layer_mm`,
  `laminar_bl_mm`, `lam_turb_transition_mm`, `element_length_mm`, `rail_deviation_deg`

### 4. New this run — a per-element speed disagreement

The extractor warned that per-element scan speeds disagree beyond 6 s.f. in **1 of 667** operating
points (worst relative spread 1.555e-06). Negligible for modelling, but it means the median is no
longer merely "the representative value" for that one row. Recorded rather than suppressed.

## Boards

- 27 boards; **13 scanned, 14 not** (was 12/15 before 2026-08-28).
- The only three **negative** turn radii in the library — `Jules_egg`, `blueTreck`,
  `hydroactive_Wake` — are all still **unscanned**. They are the opposite turn direction, and the
  thing that would fill the missing negative-roll side.

## Fin polars

- 134 profiles, 104 Reynolds numbers (10000 … 5018000), 360 angles (full 360°).
- Physical spot-check: NACA0006 is symmetric and returns Cl = 0.0000 exactly at 0°.

## What this data cannot establish

- **Any speed dependence.** One physical scan speed means zero information about how drag varies
  with V. The 2026-08-28 scan did not change this.
- **Turn radius as a per-point input.** Settled above: it is per-board, so any model using it is
  using a board identifier.
- **Generalisation across boards.** 13 scanned hulls is a small, non-random sample of shapes, and two
  of them are near-duplicates of each other.
- **Negative roll beyond −0.80 rad**, or negative turn radius at all.
- **Absolute accuracy.** These are SWD's model outputs, not experimental measurements. The extraction
  is verified faithful to the files — a different claim from the physics being right.
