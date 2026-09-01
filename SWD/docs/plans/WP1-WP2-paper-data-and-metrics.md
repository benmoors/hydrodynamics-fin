# WP1 + WP2 — the paper's supplementary data, and the metrics document

**Stage plan. Written 2026-08-27, moved into the repo and refreshed 2026-08-30.**

**BOTH WORK PACKAGES ARE NOW DELIVERED — 2026-08-31.**

| | Delivered | Where |
|---|---|---|
| **WP1** | the three supplementary archives, unmodified and still zipped | `SWD/data/paper-supplementary/` + `SOURCE.md` |
| **WP2** | the metrics reference, all 17 equations, audited | `SWD/docs/performance-metrics.md` |

Both delivered documents **supersede § 5 below** where they disagree with it: they were written against
the PDF, § 5 was written from notes. Corrections are listed under each work package in § 3.

This file remains the stage plan and the record of how the two packages were scoped.

Everything needed to resume without re-deriving anything. Read § 1 and § 2 first; they change what
the project can and cannot be.

---

## 1. Where things stand

**Done and verified** (see `SWD/README.md` for the full write-up):

| | |
|---|---|
| Extractor | `SWD/tools/swd_extract.ps1`, 1,195 lines, 133 Pester tests, 26/26 mutants killed |
| Dataset | **720** operating points · **6,867** element rows · 28 boards · 680,400 fin-polar rows · 0 parse failures (refreshed after the 2026-08-31 scan; was 667 / 6,388, and 617 / 5,914 before that) |
| Safety | 3 SQA rounds; write containment proven; provenance gate applied; licence + 627 MB library backed up to `…\SWD-backup\20260826\`, outside this repo |
| Docs | `SWD/README.md`, `SWD/docs/provenance-gate.md`, `SWD/docs/phase2-hydroscan.md`, `SWD/data/coverage.md`, repo-root `CLAUDE.md` |

**WP3, the speed axis, is refuted** — its premise died on 2026-08-31. Its three stage plans sit beside
this file and each opens with the refutation; see § 3 and `SWD/tools/phase2/LIVE-RUN-FINDINGS.md`.

---

## 2. Two findings that change the project

### 2.1 The surrogate as specified cannot be trained — two of its three axes do not exist

`mma3001-project-spec.md` specifies `X = (V_t, φ) → y = (R, F_drag)`. Tested against the real data:

- **`turn_radius_m` cannot be a target. SETTLED 2026-08-28, permanently.** Constant within
  **13 of 13** scanned boards, including one driven and watched end to end — so the `Single[]` that
  `Create_Chart_scan_radius` takes never reaches disk per operating point. It is board metadata, an
  SWD *input*, not an output. Training `(V,φ) → R` teaches board recognition and would score well
  while meaning nothing. The earlier "0 of 12 vary internally" was a property of the file format,
  not an artefact of a thin corpus.
- **`scan_speed_ms` cannot be a feature.** Appears to have 617 unique values; rounded to 2 dp there are
  **two** (20.00, 20.04), std 0.011. That is float noise around a single 20 m/s scan condition.

**What works instead — measured, not assumed:**

| Role | Columns |
|---|---|
| Candidate features | `roll_rad` (**718** distinct, −0.3968…1.3684 rad), `drift_deg` (11), `contact_area_m2` (720), `volume_litres` (720), `total_mass_kg` (14) |
| Candidate targets | `drag_total_n`, `lift_total_n`, `drag_friction_n`, `drag_planing_n` (720 distinct each); `drag_rail_n` (608) |
| Derived | lift/drag ratio |

**Refreshed 2026-08-31 from the 720-row table** — the figures above this line date from the 617-row
era. Full catalogue, keyed to the paper's symbols with units, domains and invalid-value handling, is
now `SWD/docs/project-io-spec.md`; treat that as authoritative and this as a pointer.

**These are candidates, not a chosen feature set.** The choice is the student's.

A 5-NN on those features predicting `log10(drag)`, with **leave-3-boards-out** grouping, scored
**mean R² = +0.52** (folds +0.82 / +0.22 / +0.38 / +0.68) against a mean-predictor baseline that was
*negative* on every fold. Real signal, generalising to unseen boards, from an untuned method.

**Data-quality filter you must apply and justify:** drag reaches **522 kN** (~53 tonnes) at high drift,
where the board is broadside — outside any surfing envelope, and it dominates the target range.
`drift ≤ 20°` leaves 359 rows / 12 boards; adding `drag < 50 kN` leaves 251.

**Rubric read:** Validation (25, heaviest) is *well* served by this — grouped split, real metrics,
credible baseline, and a genuinely strong "what this cannot establish". Negative results honestly
reported are worth more than a flattering number. The risk is downstream: BJ and Ra need `R(t)`, which
this data cannot supply. See § 2.2.

### 2.2 The paper ships public supplementary data covering everything SWD cannot

Charles et al. §2.4: *"Raw data samples of board data, IMU and EMG are provided by the authors."*
All three verified by download and inspection:

| URL (`https://ars.els-cdn.com/content/image/1-s2.0-S2590123025049114-` + …) | Inner file | Size | Contents | Rate |
|---|---|---|---|---|
| `mmc1.zip` | `Board_Sample.txt` | 107 KB | `t; SG1…SG5; aₓ,a_y,a_z; Rₓ,R_y,R_z` — board IMU **+ 5 strain gauges** | ~15 Hz, 148 rows |
| `mmc2.zip` | `EMG_Sample.txt` | 1.6 MB | 8 ch: R/L × {Upper Trap, Lat. Triceps, Semitend., Med. Gastro} µV | 2000 Hz, 20,002 rows |
| `mmc3.zip` | `IMU_Sample.txt` | 14.3 MB | ~90 col full-body surfer IMU | 2000 Hz, 20,001 rows |

All three start at **t = 225 s** — one synchronised ~10 s window of one wave.

This unlocks **Surfer-Jerk, Muscle Activity, Piloting Ratio, D_MA,J, flexion α, torsion β and the MI
ratios** — every metric previously written off — plus *measured* BJ/Ra as an independent check on the
SWD-derived versions, against the paper's published values.

**Recommended project shape:** SWD surrogate predicts **drag/lift from board state**; performance
indicators come from **measured data with published ground truth**. Two components, each independently
validated. Much stronger than validating a simulation against itself.

---

## 3. Work packages

### WP1 — Save the supplementary data *(30 min, no risk)*

Fetch the three `mmc*.zip` URLs into `SWD/data/paper-supplementary/`, keeping them zipped.
Write `SOURCE.md` recording per file: URL, DOI `10.1016/j.rineng.2025.108868`, retrieval date, bytes,
SHA-256, inner filename, column layout, sample rate, row count — each **verified by reading the
archive**, not from the filename. Quote both of the paper's statements verbatim: §2.4 above, and the
end-matter `Data availability: "Data will be made available on request"` — they are not quite
consistent and a reader should see both.

**Check the licence before committing.** Results in Engineering is Gold OA and Elsevier Gold OA is
normally CC-BY, but confirm on the article page. If unconfirmable, gitignore the files and let
`SOURCE.md` carry the URLs so the data stays reproducible without redistribution.

### WP2 — Metrics document ✅ **DELIVERED 2026-08-31**

`SWD/docs/performance-metrics.md`, 11 sections, labelled **internal working reference** at the top —
source material for the report, not report prose, and it implements nothing.

**What it added beyond this plan's scope**, none of which was anticipated here:

* **A self-consistency audit.** Equations 11–17 form a closed system, so every published figure was
  recomputed from the paper's own other figures. **71 of 72 relationships reproduce.** That gives an
  implementation 72 checkable targets instead of the two headline numbers.
* **The one failure**, isolated: Table 7's `D_MA,BJ` on wave 5 publishes 0.89 where Eq 15 gives
  `MA_N/BJ_N = 0.955`. Recorded as "does not reproduce", not resolved.
* **Signal processing**, recorded nowhere else in this repository and load-bearing because jerk is a
  third derivative: surfer IMU 4th-order Butterworth lowpass **7 Hz**; EMG 4th-order bandpass
  **20–400 Hz** then RMS over a **300 ms** window.
* **Two data defects**: Eq 9 names **Biceps Femoris** where `EMG_Sample.txt` ships **Semitendinosus**,
  and that is the same channel that is dead. Also the top-turn duration implied by Eq 11 (0.565 s on
  wave 4) disagrees with the published phase duration (0.8 s).
* **Table 9 recovered.** PDF text extraction silently drops its decimal comma, turning `−0,123` into
  `−0123`. All 40 cells were reconstructed as `M/I` and verified.

**Correction to this plan's framing of `D`.** Saying "`D` is net displacement, not path length" is
right about the equation but incomplete: the paper's own sentence introducing Eq 7 calls it *"the
length of the overall trajectory"*. The maths and the prose describe different quantities, and that is
where `mma3001-project-spec.md`'s reading came from. `surfing-performance-io.md` transcribes Eq 7
**correctly** — only `mma3001-project-spec.md` disagrees. See `performance-metrics.md` § 10.1.

### WP3 / WP4 — the speed axis, now three stage plans beside this file

Phase 2 (getting more scans out of SWD) and the re-extraction that follows are split into three
stage plans in this same directory, because they span days and a usage-limit boundary:

| File | Covers | When |
|---|---|---|
| `WP3-STEP-0-3-verification-scan.md` | locate the scan controls · snapshot · one 36 km/h verification scan · verify by re-extraction | **2026-08-30** |
| `WP3-STEP-4-batch-driver.md` | `swd_scan.ps1` + board switching + the mandatory SQA gate | **Monday 2026-08-31** |
| `WP3-STEP-5-7-batch-run.md` | the ~13 h batch · dual-speed extraction · correcting the record | after Step 4 |

They carry the automation blocker's root cause, the UIPI evidence, the corrected cost model, the
ruled-out coordinate traps and the order of work. **Nothing was lost** — this file is WP1 + WP2 plus
the reference material below, and can be picked up cold.

## 4. Routes investigated and ruled out — do not redo these

| Route | Verdict |
|---|---|
| Mecaflux MCP (`pass_mcp.php`) | **No.** Sells *Heliciel on Demand* only; SWD appears nowhere; explicitly not a licence |
| CSV / numeric export in SWD | **Absent.** 3 `StreamWriter` sites in a 70 MB assembly, all geometry/JSON/STL. No `.csv`, no `.xls` |
| Batch / CLI mode | **Absent.** `MyApplication::Main` IL=22; `CommandLineArgs` never read anywhere |
| Shaper Report | Renders PNG/BMP/JPG/PDF only. No numeric serialisation |
| Embedded database | None. The only `.db` is `Thumbs.db`, a Windows thumbnail cache |
| `doc_init\biblio\rapports_hydro.zip` | 121 scans (11 boards × 11 drift) — a **subset** of the 132 already extracted. Nothing new |
| Public surfboard dataset | None exists. SWD remains the only source for board hydrodynamics |
| Headless solver (no GUI) | **Feasible but unsafe.** Physics lives on `[Serializable]` types and needs no Form; the renderer is guarded by `running1`. **But** `element_hydrodynamique` construction needs a DX11-built mesh (`Actualiser_geometrie_surfboard` uses a live device 14×), and with no mesh `Actualiser_axe_roulis` **returns silently** — producing empty-but-plausible reports. Also `Form_shaper..ctor` contains 10× `WriteAllText` and `Form_shaper_Load` does 3× registry `SetValue` (the licence check). **Not worth it.** |

> ### ⚠️ SurfCommunity SFTP — do not use
> SWD hardcodes plaintext SFTP credentials (`ssh.strato.com`, an `sftp_SWD@…` account and password,
> host-key checking disabled). **These will not be used.** Connecting to a vendor's server with
> credentials extracted from their binary is unauthorised access, whatever the licence says. Recorded
> so the finding is not lost and nobody reaches for it later.
>
> It would not help anyway: by the client's own type rules the share carries only board and wave
> **geometry** — the scan fields on `Class_surfboard` are `[NonSerialized]`, so a downloaded board has
> no hydro data attached. Download is hardcoded to `Boards` and `Waves` only.

---

## 5. Reference — the paper's full metric set

> **Superseded 2026-08-31 by `SWD/docs/performance-metrics.md`.** That document was written against the
> PDF and audited; this section was written from notes and is kept only as the record of what WP2 was
> scoped against. **Where the two disagree, the delivered document is correct.** Known divergences: the
> `D` framing (§ 3 above), and the availability table below, which predates `project-io-spec.md`'s
> three-tier catalogue.

Charles, P-E. et al. (2026). *A novel surfing performance quantification system and multi-sensor
instrumented surfboard: A proof-of-concept.* Results in Engineering 29:108868.
DOI 10.1016/j.rineng.2025.108868. PDF in repo root.

**Sensor layer (1–3):** `V = V₀ + dV` · **flexion** `α = (C₁F₁+C₂F₂)/2` · **torsion** `β = (C₁F₁−C₂F₂)/2`

**Primary indicators (4–11):** `j = da/dt` · `J = ∫₀ᵀ C·j²/2 dt` · `C = T⁵/D²` ·
`D = √[(∫∫aₓ)²+(∫∫a_y)²+(∫∫a_z)²]` · **Board-Jerk** · **Surfer-Jerk** ·
`A_muscle = A_right + A_left` · **MA** `Σ = ∫₀ᵀ(A_TD+A_TB+A_BF+A_GM)dt` ·
`θ_z = ∫R_z dt` · **Radicality** `Ra = θ_z·R̄_z = θ_z²/(t₁−t₀)`

**Discriminators (12–16):** `D_raw,I = I_Top/Ra` · `I_N = I_Top/I_Bottom` · `D_B,I = I_N/Ra` ·
`D_MA,J = MA_N/J_N` · **Piloting Ratio** `PR = SJ/BJ` (PR = 1 ⇒ surfer in phase with board)

**Mechanical coupling (17):** `MI = M/I`, M ∈ {flexion displacement FD mm, torsion angle TA rad}

**Phases:** paddling (3 s pre-take-off) · take-off · trimming · bottom turn · top turn. Boundaries at
**`R_x(t) = 0`** sign changes. Axes: X roll, Y pitch, Z yaw.

### Availability

| Metric | From SWD | From supplementary data |
|---|:--:|:--:|
| Board-Jerk, Radicality, θ_z, R̄_z, phase segmentation | ✅ derived | ✅ measured |
| `D_raw,BJ`, `BJ_N`, `D_B,BJ` | ✅ | ✅ |
| Surfer-Jerk, Muscle Activity, PR, `D_MA,J` | ❌ | ✅ |
| Flexion α, torsion β, `MI` | ❌ | ✅ |
| Lift/drag ratio, min-drag position, manoeuvrability envelope | ✅ | ❌ |

SWD gives speed, roll, radius, drag, lift → `aₓ = dV/dt`, `a_y = V²/R`, `a_z = (F_lift−mg)/m`,
`R_x = dφ/dt`, `R_z = V/R`.

### Validation targets

| Quantity | Wave 4 | Wave 5 |
|---|---:|---:|
| R̄_z (rad/s) / θ_z (rad) | 2.94 / 1.66 | 1.48 / 2.04 |
| **Ra (rad²/s)** | **4.89** | **3.02** |
| D_raw,BJ · BJ_N · D_B,BJ | 14.81 · 1.28 · 0.26 | 44.35 · 1.77 · 0.59 |
| FD (mm) / TA (rad) | −0.60±0.15 / 0.11±0.01 | −0.10±0.02 / −0.06±0.005 |

BJ by phase: take-off 60.97/90.13 · trimming 174.62/401.50 · bottom 56.32/75.41 · top 72.34/133.73 ·
end 96.23/91.52 · **full wave 460.47/792.28**. PR full-wave **1.04 / 0.49**.
Check: `1.66 × 2.94 = 4.88 ≈ 4.89` ✓

### The paper's own limitations, to carry across
Unique oceanic waves that cannot be duplicated — the authors state **no conclusions on surfing
performance should be drawn from the in-situ experiment alone**. Indicators are only meaningful between
comparable waves. Board precision **24.6 % flexion, 8.9 % torsion**. Nose behaviour not measured.

---

## 6. Standing technical facts — do not rediscover

- `BinaryFormatter` needs **Windows PowerShell 5.1**, not `pwsh` 7+ (removed in .NET 9).
- The `AssemblyResolve` handler must return an **already-loaded** assembly and never call `LoadFrom`
  inside itself — that recurses into an uncatchable `StackOverflowException`. Happened twice.
- Never call `asm.GetTypes()` bare — throws `ReflectionTypeLoadException`. Catch and filter, or use
  `GetType(name)`.
- Never string-interpolate a reference-typed field — formatting the cyclic graph is the other overflow.
- **36 of 101** `element_hydrodynamique` fields are `[NonSerialized]` and deserialise as fake zeros —
  including both yaw moments. Yaw rate is derived as `R_z = V/R`.
- Field names carry French accents; build them from explicit char codes. Polar XML uses **comma decimal
  separators**.
- CSV must be UTF-8 **without BOM**.
- SWD seawater density is **exactly 1023 kg/m³** for these scans — salt water at 30 °C, from a
  4-entry lookup table recovered by decompilation. `ṁ/A` = 20460.000 ± 0.002 on a single-temperature
  board. The old "1023.154 ± 10.68, not an exact 1023" averaged a bimodal 1023/1025 mixture.
- `elements.csv` rows are **not** independent samples. Group any split **by board**.
- Known artefacts: 58 `Single.MaxValue` sentinels in `element_width_mm` (filter `>1e30`); 12 negative
  `cd` rows in `fin_polars.csv`.
- Never write inside `C:\Program Files\ShaperWaveDynamics\`; never modify `biblio\` in place.

## 7. Still open, your call

1. **The `board` join key carries designer/model names** — it is the key across all three tables, so
   hashing or dropping it is an observable format change.
2. **`fin_polars.csv` is 48.3 MB**, regenerates in ~80 s. Under GitHub's 50 MB warning but permanent
   once committed. Consider gitignoring.
3. ~~**SWD may still be running** (pid was 59224).~~ **Closed 2026-08-27** — no `SurfHydrodynamics`
   process is resident. Nothing to do.

---

## 8. Added 2026-08-31 — the reference-velocity check that strengthens WP2

Every operating point sits at one velocity and no control in the application changes it
(`SWD/docs/what-swd-can-yield.md` § 3). A trajectory at any other speed needs `F(V) = F_ref (V/V_ref)²`,
which **this dataset cannot test**.

It does pass an independent check. Solving `lift(V_eq) = (m_surfer + m_board) g` at an 80 kg surfer:

| Board class | `V_eq` |
|---|---|
| shortboards | **7.6 – 8.5 m/s** |
| `DanielThomson_ModernPlaningHull` | 5.9 |
| guns | 2.2 – 2.7 |
| `default_longboard` | **1.67** |
| `default_paddle` | **1.14** |

Shortboards plane at ~8 m/s, inside the real 3–10 m/s surfing range; high-volume hulls plane at
walking pace. Nothing was tuned to produce it. **This belongs in WP2's availability matrix** — it is
corroboration from independent physics for the one assumption the corpus cannot test itself.
