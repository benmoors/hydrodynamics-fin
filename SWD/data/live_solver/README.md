# 📘 Live-solver tables: `default_shortboard`, one 80 kg surfer

### 🎯 Learning Objectives

> - Know what one row is: one board attitude (scan position) re-solved by SWD at one speed and slope
> - Choose between the two sections: every read, or only the reads where lift reached the weight
> - Read the columns, their units and the convergence flag correctly

---

## 1. What these tables are

With Board Dynamics ON, ShaperWaveDynamics (SWD) has a live trim solver. Each scan position from the board's hydroscan
(drift, Pos Y, Pos X) is re-solved at the applied flow speed and slope, and the solver holds lift at the weight of board
plus surfer where it can. The Stage 2 campaign read that solver for every position on a grid of speeds and slopes,
across two nights (2026-10-06 to 2026-10-08), with no hand input.

| Item | Value |
|---|---|
| Board | `default_shortboard` (24.86 L board-grid volume) |
| Surfer | 80 kg (SWD's window caption) |
| Weight plateau | 802.21 N (the most common converged lift) |
| Speeds (`flow ms`) | 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 m/s |
| Slopes | −10, −5, 0, +5, +10, +15, +20° |
| Drifts | 0, 2, 5, 10, 15, 20° |
| Positions | 282 (45, 46, 49, 47, 47 and 48 per drift; Pos Y and Pos X as SWD's hydroscan defines them) |
| Reads | 19,740 = 282 positions × 10 speeds × 7 slopes |
| Read order | speed → slope (one Apply) → drift → Pos Y → Pos X |

All 70 (speed, slope) blocks passed a block control: the first position, re-read at the end of the block, matched row
for row. No read showed the wrong position, and none was a stale copy of the read before it.

---

## 2. The two sections

| Folder | Rows | What is in it |
|---|---:|---|
| `default_shortboard/all_reads/` | 19,740 | every read, converged or not |
| `default_shortboard/converged/` | 7,745 | only the reads whose lift is within 1 % of the weight plateau |

Each folder holds the same two files:

| File | Columns | Contents |
|---|---:|---|
| `solver_points.csv` | 28 | the position and situation, 14 key solver outputs, and the QA columns |
| `solver_points_all_columns.csv` | 87 | the same rows with every row of SWD's analysis grid |

> **Point of note:** the unconverged reads are kept on purpose (Benjamin, 2026-10-08). Where lift falls short of the
> weight, the solver found no equilibrium trim, so the forces in that row describe the attitude the solver stopped at, not
> a ridden board. Use `converged/` for anything that assumes equilibrium, and `all_reads/` to see where the board stops
> planing.

---

## 3. Columns

**Keys:** `board`, `speed_ms`, `slope_deg`, `drift_deg`, `pos_y`, `pos_x`.

**Key outputs** (`solver_points.csv`), with their SWD grid row:

| Column | Unit | SWD row |
|---|---|---|
| `lift_n` | N | `portance_globale_verticale_n` |
| `fz_planing_n` | N | `Fz_planing_n` |
| `friction_n` | N | `Fx_friction_n` |
| `fx_planing_n` | N | `Fx_planing` |
| `fx_rail_n` | N | `Fx_rail_n` |
| `drag_total_n` | N | `trainée_globale_horizontale_n` |
| `yaw_moment_nm` | N·m | `Moment_yaw_hydrodynamic_nm` |
| `planing_angle_deg` | ° | `angle_planing_effectif_deg` |
| `delta_plan_deg` | ° | `delta_plan_horizontal_deg` |
| `wetted_area_m2` | m² | `surface_contact_m2` |
| `wetted_length_mm` | mm | `longueur_mouillée_element_mm` |
| `volume_l` | L | `volume_litres` |
| `mass_flux_kg_s` | kg/s | `masse_flux_dévié_kg_sec_planing` |
| `hydrostatic_fx_n` | N | `Fx_deplacement_hydrostatique_n` |

**All columns** (`solver_points_all_columns.csv`) add the rest of the analysis grid. The rows SWD names in French carry
English names, translated through `SWD/tools/column_names.csv`, which keeps each SWD name beside its English one; the rest
keep SWD's own names. `SWD/docs/column-names.md` explains how each translation was checked. Units follow the name suffix
(`_n` N, `_nm` N·m, `_deg` °, `_m2` m², `_mm` mm, `_litres` L, `_kg_s` kg/s, `_m3_s` m³/s, `_ms` m/s, `_m` m, `_pa` Pa).
Three rows are vectors written as one quoted `"x, y, z"` text cell: `normal_force_application_point`, `buoyancy_vector_n`
and `effective_buoyancy_vector_n`. A few rows are SWD constants or object names (`name`, `info`, `internal_elements`), and
three only ever read `(Collection)`: `element_outline_polygon_m` and the two `roll_axis_section_normal_*` rows.
`planing_info` reads `angle_max` where the solver stopped at its angle limit and `planing` otherwise.

**QA columns:**

| Column | Meaning |
|---|---|
| `lift_dev` | lift / weight plateau − 1. Within ±0.01 is converged |
| `element_match` | the analysis tree showed the position that was selected |
| `element_label` | SWD's own label for it (SWD writes some Y and drift values with a minus sign; matched by magnitude) |
| `same_as_previous` | every grid row equal to the read before it (a possible stale read) |
| `select_ms`, `settle_ms`, `read_ms` | timing of the read |
| `seq` | read number in campaign order |

---

## 4. What the data can and cannot support

- **One board and one surfer.** Nothing here varies geometry or mass.
- **Slope is a calm-water surface slope,** not a wave. There are no wave or fin inputs.
- **Roll is not an input.** It enters only through the scan positions (Pos Y).
- **Rows are not independent samples.** Neighbouring positions on one board are strongly correlated, so a random
  train/test split leaks between them.
- **Read order matters slightly.** The solver starts each position from the answer for the one before. Reading in reverse moved
  total drag by up to 0.15 % and planing angle by up to 1.3 % (2026-10-05 pilot, on `default_shortboard_Copy_1`).
- **Convergence depends strongly on speed and on Pos X.** No position converges at 1 m/s; 104–120 of 282 do at 5 m/s and
  187–197 at 10 m/s. The first Pos X station of every (drift, Pos Y) group never converges, even at 10 m/s.

---

## 5. Provenance and regeneration

The raw reads (`solver.jsonl`, one record per read with all 73 grid rows) stay outside the repository. These tables come
from them through `SWD/tools/phase2/swd_solver_table.py`, which has a `--self-test`:

```
py -3.14 SWD/tools/phase2/swd_solver_table.py --dir <solver dir> --out <csv> [--all] [--converged]
py -3.14 SWD/tools/translate_columns.py <csv>
```

`--all` writes every grid row, and `--converged` keeps only the converged reads. The second command gives the rows SWD
names in French their English headings; it changes only the header line. The campaign, its checks and its
results are recorded in `SWD/TODO.md` and `AI-USE.md`.

---

## 🤖 AI Acknowledgment

**What AI was used.** Claude Opus 5.5 via Claude Code 2.1.289–2.1.292 (Anthropic), 5–8 October 2026, for the rig,
the campaign and these tables. In the SQA pass of 8 October, the Antigravity CLI 1.3.1 and the Devin CLI 3000.11.3 also
reviewed and fixed the rig code. The full record is `AI-USE.md` §§ 2, 4 and 5.

**How AI was used.** AI wrote the automation that drove SWD, ran the two-night campaign, generated these tables with
`swd_solver_table.py`, and drafted this README. The board, the speed and slope levels, the read order, splitting the
run by night, keeping the unconverged reads and publishing both sections were my decisions (`AI-USE.md` § 4).

**Human oversight and responsibility.** Every block was re-checked by re-reading its first position, every read was
checked against the position selected, and the SWD library was hashed before and after every chunk. The tables are
regenerated from the raw records by a tool with a self-test, not retyped.

**Errors the AI made.** After opening a board, its reader found no analysis grid because nothing was selected in it (E123).
The night driver had no time limit on its child processes and could open any board (E124). One review agent made the
restore ignore the STOP file, which the final review reverted (E125).
