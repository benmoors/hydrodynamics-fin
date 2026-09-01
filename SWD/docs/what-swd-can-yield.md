# 📘 What SWD Can and Cannot Yield

> ### ⚠️ Correction, 2026-09-01 — `20.0391 m/s` is not a speed
> Decompiling `Form_shaper.actualiser_fluide()` showed SWD picks water density from a
> **4-entry lookup table** (salt `1028/1027/1025/1023` by temperature ∈ {0,10,20,30} °C),
> never a formula. `mass_flux/frontal_section` is exactly `ρ·V` and takes exactly two
> corpus-wide values, **20460.0** and **20500.0** = `1023×20.000` and `1025×20.000`.
> So the corpus is **one flow speed (20.000 m/s) at two water temperatures**, and the
> phantom second speed was `20500/1023 = 20.0391` — the 1025-density scans divided by an
> assumed 1023. Wherever this file treats 20.039 as a speed or as float noise, read it as
> a ρ = 1025 scan instead. **The conclusion that `flow ms` does nothing is unaffected and
> in fact strengthened**: the flow speed was 20.000 throughout. See `CLAUDE.md` § 5.



### A complete account of the data obtainable from ShaperWaveDynamics

Written 2026-08-31 after driving the application under tool control for the first time. Everything
here was **measured on the running application or read out of its files** — where something is
inference, it is labelled as such.

---

### 🎯 What this document settles

> * There are **two scan modes**, not one, and only one of them writes anything to disk.
> * The static hydroscan appears to run at a **fixed reference velocity**. No control anywhere in the
>   UI changes it.
> * Which columns are real physics, which are structurally unavailable, and which are fake zeros.
> * What the speed axis would cost, and why scanning is probably the wrong way to get it.

---

## 📂 1. The two scan modes

Both are behind the **same button** (`Hydrodynamics Scanner`). Which one fires depends on whether a
wave is loaded.

| | **Static hydroscan** | **Dynamic scan** |
|---|---|---|
| Precondition | **no wave loaded** (`<no Wave>` in the title) | a wave is loaded |
| What it does | sweeps a fixed set of drift angles | time-domain pass over the wave |
| Duration measured | ~61 s per angle, ~12 min for 11 angles | **1 second** |
| Writes to disk | **one `.fynrhydro` per angle** | **nothing** |
| Message on completion | `Scaned drifts angles list (11 angles saved)` | `Scan dynamic completed / Scan duration: 1 seconds` |

**With a wave loaded, `HydroScan`, `Compute` and `Solve Planing` are all disabled** (`en=False`,
measured). The modes are mutually exclusive.

> ### ⚠️ Point of note — the dynamic scan produced no extractable artefact
> A full library sweep for files written during the dynamic scan found exactly one: the board's own
> `.fynbs`. No report, no export, nothing new. **Every number this project trains on comes from the
> static hydroscan.** If the dynamic scan holds results, they live in memory and there is no
> discovered route to them.

### 🔹 The drift angle set is not parameterisable

The scan runs SWD's own set — **`0, 2, 5, 10, 15, 20, 30, 45, 60, 75, 90`**, 11 angles. There are no
min/max/step controls; the panel offers a `Drift Angle` trackbar and a read-only label only.

The start dialog states *"Each Scaned angle Is saved when computed / You can Stop the scan, And
restart it later..."*, and this was confirmed — files appeared one per angle as computed. **Stopping
early is the only way to get a subset, and partial results survive.**

---

## 📂 2. Every scan-relevant input in the application

Enumerated exhaustively from the live control tree, not from documentation.

| Control | Class | Value seen | What it actually drives |
|---|---|---|---|
| `flow ms` | EDIT | 10 | **the single-point solver only** |
| `Slope°` | EDIT | 0 | single-point solver |
| `Surfer Kg` | EDIT | 80 | single-point solver; matches the title's `Surfer Pro(80Kg)` |
| `Drift Angle` | trackbar | — | selects an angle to *explore*, not to scan |
| Wave (loaded/not) | — | — | **selects which scan mode fires** |
| `Solver option:` | 3 buttons | — | `Compute`, `HydroScan`, `Solve Planing`. **No numeric fields at all** |

**That is the complete list.** `Solver option:` was the last unexplored surface and contains only
buttons.

### 🔹 `flow ms` drives the solver, and this was proven twice over

The `Solve Planing` button's own caption reads back the value:

    Relative speed:10 m/s, Attack:5.0°, Drift 0°
    Planing:100%

after `flow ms` was set to 10. So `flow ms` is genuinely a speed input — just not the hydroscan's.

> ### ⚠️ The unit claim in `BUILD-NOTES.md:86` is wrong
> It asserts the speed boxes are `NumericUpDownScanSpeed{1,2,3}kmh`, in **km/h**, with a standing
> instruction to convert via `ConvertTo-Kmh` and *"never type"* the m/s number.
>
> **No such control exists.** The box is labelled `flow ms` — metres per second — verified
> independently because its sibling `Surfer Kg` reads 80 and the window title reports `80Kg`. Typing
> the planned `36` would have requested 36 m/s ≈ 130 km/h. **Never apply `ConvertTo-Kmh` here.**

---

## 📂 3. The speed axis — the central negative result

**Every hydroscan ever produced on this installation ran at ~20 m/s.** Across 154 reports and 14
boards, the recovered `scan_speed_ms` takes exactly two values: **20.000** (566 rows, older scans)
and **20.0391** (154 rows, both driven scans).

Speed is recovered *independently* by the extractor, from the planing mass balance `ṁ = ρAV` — not
read from a stored field, so it is a genuine measurement of the condition each report was computed at.

### 🔹 The direct experiment

`flow ms` was set to **10**, readback-asserted as **10**, and logged as 10 immediately before the scan
started. All **53** resulting operating points came back at **20.0391 m/s**.

### 🔹 The corroborating evidence, all independent

* **No other candidate control exists** (§ 2), and `Solver option:` holds no numerics.
* The stored `board_speed_setting_ms` ranges over 2–20 across the library while **every** recovered
  scan speed is ~20 — so the stored setting has never been the scan condition.
* Two near-identical shortboards stored at 20 and 5 m/s have a median drag ratio of **1.11×**. V²
  scaling between 20 and 5 m/s would demand **16×**. They were scanned at the same speed.
* The copy branch reset a board's stored setting from 10 to **20** on its own.

### 🔹 The conclusion, stated at the confidence the evidence supports

> **High confidence:** no user-reachable control changes the hydroscan's velocity.
>
> **Medium confidence (inference, not measurement):** the hydroscan is a **drag polar computed at a
> fixed reference velocity**, the wind-tunnel convention. Nothing was decompiled to confirm a
> hardcoded constant, so this remains the best explanation rather than a proven mechanism.

**If that reading is right, the speed axis was never obtainable by scanning**, and the 5–13 hour batch
in `WP3-STEP-4-batch-driver.md` would have produced 26 boards at one speed — the corpus it already
has. The alternative is to treat the scan as a polar at reference velocity and obtain other speeds by
**V² scaling downstream**, which is standard hydrodynamics and costs no machine time.

That should be **stated as a modelling assumption and validated**, not assumed silently: the honest
form is to model drag as `F(V) = F_ref · (V/V_ref)²` and say plainly that the dataset cannot test it,
because every sample sits at one velocity.

---

## 📂 4. What the files actually contain

Four tables, all produced by `SWD/tools/swd_extract.ps1` reading the binary formats directly. SWD
itself has **no export of any kind** — no CSV, no numeric report, no CLI, no database.

| Table | Rows | Cols | What it is |
|---|---:|---:|---|
| `operating_points.csv` | 720 | 19 | **the training table** — one row per (board, drift, equilibrium) |
| `elements.csv` | 6,867 | 22 | the spatial mesh along each board. **Not independent samples** |
| `boards.csv` | 28 | 10 | per-board geometry and metadata |
| `fin_polars.csv` | 680,400 | 7 | Re / angle / Cl / Cd / Cm across 134 profiles |

### 🔹 What is structurally unavailable

* **36 of `element_hydrodynamique`'s 101 fields are `[NonSerialized]`** and deserialise as 0/null
  regardless of the real physics — including **both yaw-moment fields**, every `_projection_*`,
  `_list_vitesse_moyenne_veine_ms`, `planche_ref` and `infos_planing`. They never reach disk, so no
  reader can recover them. Yaw rate is derived as `R_z = V/R` instead.
* **13 further element columns are `System.Single` fields SWD's hydroscan path never assigns.** They
  deserialise to a real `0.0f`, so a null check cannot catch them — only a constant-column check can.
  The extractor drops them by name at write time; exporting them would read as data.
* **`structure_mass_kg`** is zero on all 28 board rows and is dropped for the same reason.

### 🔹 Known artefacts a consumer must handle

* 58 `Single.MaxValue` sentinels in `element_width_mm` — filter `> 1e30`.
* 12 negative `cd` rows in `fin_polars.csv`.
* Per-element scan speeds disagree beyond 6 s.f. in **1 of 720** operating points (worst relative
  spread 1.555e-06), so the median is not merely "the representative value" for that row.
* Drag reaches **522 kN** at high drift where the board is broadside — outside any surfing envelope,
  and it dominates the target range. `drift ≤ 20°` is the defensible filter.

### 🔹 Two columns that look like features and are not

* **`turn_radius_m` is per-board metadata, constant within 14 of 14 scanned boards.** It is an SWD
  *input*, never a per-point output. Training `(V, φ) → R` teaches board recognition.
* **`board_speed_setting_ms` is the GUI box as it stood when the board was last saved**, not the scan
  condition. Using it as a feature trains on a label that does not describe the physics.

---

## 📂 5. Routes that do not exist

Each was investigated and closed; none should be retried.

| Route | Verdict |
|---|---|
| CSV / numeric export in SWD | **Absent.** 3 `StreamWriter` sites in a 70 MB assembly, all geometry/JSON/STL |
| Batch / CLI mode | **Absent.** `MyApplication::Main` IL=22; `CommandLineArgs` never read |
| Shaper Report | Renders PNG/BMP/JPG/PDF only. No numeric serialisation |
| Embedded database | None. The only `.db` is a Windows thumbnail cache |
| `rapports_hydro.zip` in `doc_init` | 121 scans — a **subset** of what is already extracted |
| Public surfboard dataset | None exists. SWD is the only source for board hydrodynamics |
| Headless solver, no GUI | **Feasible but unsafe** — needs a DX11-built mesh; without one `Actualiser_axe_roulis` returns silently, producing empty-but-plausible reports |
| Vendor SFTP share | **Never to be used** — hardcoded credentials; and by the client's own type rules it carries geometry only, no hydro data |

---

## 📂 6. What remains untested

Listed so nothing above reads as more complete than it is.

* **Whether a hardcoded reference velocity exists in the assembly.** § 3's conclusion is inference.
  A targeted look at the hydroscan method would settle it, and would be cheap next to another scan.
* **Whether the dynamic scan's results are reachable at all** — in memory, via a chart export, or
  through the `Time flow` panel's `Save instant` button, which was never pressed.
* **What `Attack:5.0°` is set by.** It appears in the `Solve Planing` caption but no control for it
  was found.
* **A surfer mass of 50 kg was reported on screen** during the run while every instrument read 80 —
  the box, the window title, and the configuration panel. The control was never located.
* **Whether unloading the wave restores `HydroScan` to enabled.** Strongly expected, not yet observed.

---

## 📂 7. Practical consequences

1. **Do not run the Step 4 batch to obtain a second speed.** On the evidence it would return 26
   boards at ~20 m/s. Settle § 6's first item first.
2. **A batch is still worth running for geometry variety** — 13 unscanned boards, ~12 min each at
   ~20 m/s. That widens hull coverage, which is a real axis the corpus is thin on.
3. **Never scan a protected library original.** SWD diverts through a save-as-copy branch that
   **resets the board's physics metadata** — a 22.806 m turn radius came back as 100000, and the
   speed setting 10 came back as 20. Scan copies you made yourself, and re-read parameters afterwards.
4. **Report the single-velocity limitation in the write-up.** The brief asks explicitly what the
   validation cannot establish, and "every sample sits at one speed, so no claim about speed
   dependence is supported" is exactly that kind of statement.
