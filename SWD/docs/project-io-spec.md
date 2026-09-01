# 📘 Project Inputs and Outputs

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



### What SWD offers, keyed to the paper's own symbols

A **catalogue of what is available**, not a chosen design. Every quantity Charles et al. (2026) define
is listed against what this project can actually supply for it, with the measured range attached, so a
modelling decision can be made from evidence rather than from the supplied specification's assumptions.

All figures measured **2026-08-31** from `SWD/data/` — 720 operating points, 14 scanned boards, 28 board
rows, 6,867 element rows, 680,400 fin-polar rows. Nothing here is copied from an earlier document.

---

### 🎯 What this document is for

> * To let a feature set be **chosen**, by showing what exists, what varies, and what does not.
> * To supply the rubric's inputs-and-outputs requirement: data type, unit, operating range,
>   mathematical domain, and how invalid or out-of-bounds values are handled.
> * To record two defects in the supplied specification rather than silently working around them.

**Scope.** This document stops at the data. The surrogate, Board-Jerk, Radicality, the trajectory model
and the report are separate work and are not written here.

---

## 📂 1. The organising fact

**SWD is a force model, not a kinematics model.**

It answers one question: *what forces act on this hull, at this attitude, at a reference velocity.* It
does not produce a trajectory. Every kinematic symbol in the paper — `V(t)`, `R(t)`, `a_x`, `a_y`,
`R_x`, `R_z` — has to come from a trajectory model.

That is not a limitation to work around; it is the architecture the project already assumes, with the
surrogate "queried at 100 Hz along a synthetic on-wave trajectory". It is also **why the two degenerate
columns do not block the project**: the trajectory supplies speed and radius, so it does not matter that
SWD's are fixed.

---

## 📂 2. The catalogue

### 🔹 Tier 1 — directly available from SWD

| Paper role | Column | Type | Unit | Range | Distinct |
|---|---|---|---|---|---:|
| `F_lift`, feeding `a_z = (F_lift − mg)/m` | `lift_total_n` | float64 | N | 982.00 … 894,598.64 | 720 |
| `F_drag` | `drag_total_n` | float64 | N | 157.40 … 522,339.15 | 720 |
| drag decomposition | `drag_friction_n` | float64 | N | 16.90 … 5,169.38 | 720 |
| | `drag_planing_n` | float64 | N | 46.99 … 512,481.74 | 720 |
| | `drag_rail_n` | float64 | N | **−5,540.62** … 15,950.97 | 608 |
| roll attitude `φ` | `roll_rad` | float64 | rad | −0.3968 … 1.3684 | **718** |
| roll bounds | `roll_min_rad` / `roll_max_rad` | float64 | rad | −0.7984 … 1.4909 | 713 / 718 |
| drift (yaw attitude) | `drift_deg` | float64 | ° | 0 … 90 | 11 |
| wetted area | `contact_area_m2` | float64 | m² | 0.0240 … 9.9179 | 720 |
| immersed volume | `volume_litres` | float64 | L | 0.6457 … 799.3711 | 720 |
| board mass, part of `m` | `total_mass_kg` | float64 | kg | 1.7405 … 6.5832 | 14 |
| mesh resolution | `n_elements` | int | — | 2 … 13 | 12 |
| roll case index | `roll_case` | int | — | 0 … 4 | 5 |
| fin section data | `fin_polars.csv` | float64 | — | Re / angle / Cl / Cd / Cm | 680,400 rows |

**`roll_rad` is the widest genuine axis in the dataset** — 718 distinct values across 720 rows.

### 🔹 Tier 2 — must come from the trajectory model

| Paper symbol | Definition | Why not from SWD |
|---|---|---|
| `V(t)` | trajectory speed | the corpus holds **one physical value** |
| `R(t)` | turn radius | per-board constant; an SWD **input**, not an output |
| `a_x` | `dV/dt` | derivative of a trajectory quantity |
| `a_y` | `V²/R` | both terms are trajectory quantities |
| `R_x` | `dφ/dt` | SWD gives static `φ` per operating point, not `φ(t)` |
| `R_z` | `V/R` | as above |
| `t₀`, `t₁` | `R_x = 0` crossings | requires `R_x(t)` |

### 🔹 Tier 3 — not obtainable from SWD

| Paper symbol | Eq | Requires | Available elsewhere? |
|---|---|---|---|
| `α` flexion, `β` torsion **of the board** | 2, 3 | the 5 strain gauges | ✅ `mmc1` |
| Surfer-Jerk | 8 | full-body IMU | ✅ `mmc3` |
| `A_muscle`, `MA Σ`, `D_MA,J` | 9, 15 | 8-channel EMG | ✅ `mmc2` (7 usable channels) |
| `PR = SJ/BJ` | 16 | both jerk series | ✅ `mmc1` + `mmc3` |
| yaw moment | — | — | ❌ both fields are `[NonSerialized]` |

The paper's supplementary archives are already saved under `SWD/data/paper-supplementary/` with full
provenance in `SOURCE.md`. **That is the natural two-component shape: SWD for board forces, measured
data for the surfer-side indicators**, each validated independently.

---

## 📂 3. The two columns the supplied specification gets wrong

`mma3001-project-spec.md` Part 4 § 3 names features `(V_t, φ)` and targets `(R, F_drag)`. Measured:

| Spec role | Column | Measured reality |
|---|---|---|
| Feature | `scan_speed_ms` | 20.0000 … 20.0391 — **one physical condition**. 650 "distinct" values are float noise; rounded to 2 dp there are two |
| Target | `turn_radius_m` | **9 values, constant within every one of the 14 scanned boards** |

`turn_radius_m` is board metadata, so training `(V, φ) → R` learns board identity and would score well
while meaning nothing. `yaw_rate_rad_s` is derived from it and inherits the same defect.

> ### ⚠️ Point of note — this is validation material, not just a blocker
> The rubric's heaviest item rewards engineering credibility. A measured demonstration that a specified
> model is untrainable, with the evidence attached, is a stronger result than a flattering R² obtained
> by predicting a constant.

---

## 📂 4. Invalid, missing and out-of-bounds handling

Required explicitly by the rubric. Every artefact below was re-measured today.

| Artefact | Where | Count | Handling |
|---|---|---:|---|
| `Single.MaxValue` sentinels | `elements.csv` `element_width_mm` | **68** | filter `> 1e30` |
| Negative drag coefficient | `fin_polars.csv` `cd` | **12** | exclude or flag; unphysical |
| Negative rail drag | `drag_rail_n` | **33** of 720 | **legitimate** — the rail can generate thrust; do not filter. All 33 occur at drift ≤ 10°, most negative −5,540.62 N |
| Zero rail drag | `drag_rail_n` | **113** of 720 | rail not engaged at that attitude; a real value, not missing data |
| Constant-zero columns | `elements.csv` | 13 dropped | already removed at extraction; never re-add |
| Fake-zero fields | `element_hydrodynamique` | 36 of 101 | `[NonSerialized]`; unrecoverable by any reader |
| Missing board row | `operating_points` join | 0 currently | extractor emits `NaN` speed/radius/mass and warns |
| Per-element speed disagreement | `scan_speed_ms` | 1 of 720 | worst relative spread 1.555e-06; median is representative but not exact |

> ### ⚠️ The sentinel count has moved
> Earlier documents record **58** `Single.MaxValue` sentinels. After the 2026-08-31 scan grew
> `elements.csv` from 5,914 to 6,867 rows it is **68**. Re-measure rather than quoting a prior figure.

### 🔹 Structural constraints on any split

* **Group by board.** Rows from one board share speed, radius and mass exactly, so a random split
  leaks. `operating_points.csv` (720 rows, 14 groups) is the training table.
* **`elements.csv` is not independent samples.** It is the spatial mesh along one board at one
  condition — near-duplicate rows straddle any random split and inflate R².
* **Drift > 20° is outside the surfing envelope.** The board is broadside and drag reaches 522 kN
  (~53 t). `drift ≤ 20°` leaves **419 rows across all 14 boards**, `roll_rad` −0.2004 … 1.3684,
  `drag_total_n` 389.7 … 470,186.9 N.

---

## 📂 5. The reference-velocity question

Every operating point sits at `V_ref ≈ 20.04 m/s`, and no control in the application changes it
(`what-swd-can-yield.md` § 3). A trajectory at any other speed therefore needs

    F(V) = F_ref · (V / V_ref)²

**This dataset cannot test that relation** — a single-velocity corpus has no leverage on velocity
dependence — so it must be carried as a stated modelling assumption.

### 🔹 An independent check it happens to pass

Solving `lift(V_eq) = (m_surfer + m_board)·g` for an 80 kg surfer, per board:

| Board | `V_eq` (m/s) |
|---|---:|
| `default_shortboard` | 8.52 |
| `2003_Taylor_Knox_channel_island_Copy_1` | 8.40 |
| `default_shortboard_Copy_3` | 8.36 |
| `Bettsy_TowIn` · `default_shortboard_Copy_1` | 8.29 |
| `default_evolutive` | 8.09 |
| `Poahaku` | 8.02 |
| `Mini_Simmons` | 7.84 |
| `default_fish` | 7.64 |
| `DanielThomson_ModernPlaningHull` | 5.92 |
| `Laser_Zap_Ben_Aipa` | 2.70 |
| `Bruce Iron Brewer Gun` | 2.15 |
| `default_longboard` | **1.67** |
| `default_paddle` | **1.14** |

Shortboards plane at ~8 m/s — inside the observed 3–10 m/s surfing range — while high-volume hulls
plane at walking pace, which is what a paddleboard physically does. **Nothing was tuned to produce
this**; it falls out of scaling SWD's lift and setting it equal to weight.

That is corroboration from independent physics, not proof. It is offered as validation material;
whether the project adopts V² scaling is a modelling decision.

---

## 📂 6. Output schema, and the ICM-20948

The paper's `mmc1` inner file is:

    t ; SG1 ; SG2 ; SG3 ; SG4 ; SG5 ; a_x ; a_y ; a_z ; R_x ; R_y ; R_z

The six kinematic channels are **exactly what an ICM-20948 produces**. Emitting the simulation in that
schema means one Board-Jerk / Radicality implementation processes the simulated run, the paper's
measured wave, and a future fin-PCB log without modification — and the paper's published
`Ra = 4.89` / `3.02 rad²/s` become external validation targets rather than internal consistency checks.

### 🔹 What the simulation implies for sensor configuration

| Quantity | Simulated / published value | Implication |
|---|---|---|
| `R_z = V/R` at 8 m/s, tightest corpus radius 19.08 m | 0.42 rad/s (24 °/s) | — |
| `R_z` on a real 5 m carve | ~1.6 rad/s (92 °/s) | — |
| `R̄_z` **measured in the paper** | **2.94 rad/s (168 °/s)** | **±500 °/s** gives ~3× headroom; ±250 would clip |
| `a_y = V²/R`, corpus minimum radius | 0.34 g | — |
| `a_y` on a 5 m carve | ~1.3 g | **±8 g** a sensible default; ±16 g only if clipping appears |
| Paper's board IMU rate | ~14.6 Hz, non-uniform | the spec's 100 Hz is well above it |

**Jerk is a derivative of acceleration**, so sampling and filtering choices matter more than raw rate:
differentiation amplifies high-frequency noise, and `J` integrates the *square* of it.

---

## 📂 7. Downstream hardware notes

Recorded because they bear on the sensor the simulation is meant to inform. **Not assignment scope** —
the PCB is later work.

### 🔹 Magnetometer

`fin_sensor_pcb_overview.md` concludes absolute heading is "not a design requirement". That is too
strong, and the reasoning splits three ways:

* **Yaw has no gravity reference.** Roll and pitch can be corrected against gravity; yaw cannot.
  Gyro-only yaw drifts without bound — a ±0.2 °/s MEMS bias reaches order 100° over ten minutes. A
  magnetometer is the only absolute horizontal reference.
* **But Radicality does not need one.** `θ_z` is integrated over a single maneuver, `t₀` → `t₁`,
  typically 1–3 s, where that bias contributes well under 1° against a swept angle of ~1.7–2.0 rad.
  The paper obtained its published `Ra` values on an **Arduino Nano RP2040 Connect — a 6-DoF IMU with
  no magnetometer at all.**
* **The distortion objection concerns uncalibrated use.** Hard-iron error is a per-axis offset;
  soft-iron error is an ellipsoid distortion corrected by a scale matrix. Both are routine, and the
  AK09916 die is already inside the ICM-20948 package — the cost is a calibration procedure, not
  hardware.

**Net:** the magnetometer earns its place for session-level heading and trajectory reconstruction;
Radicality specifically does not depend on it. Both halves should be stated.

### 🔹 Pressure sensor

`fin_sensor_pcb_overview.md` describes dynamic pressure as "much smaller" than hydrostatic. At surfing
speed the ordering is the other way round:

| Component | Expression | At a fin |
|---|---|---|
| Dynamic | `½ρV²` at 8 m/s, ρ = 1023 | **~32.7 kPa (0.33 bar)** |
| Hydrostatic | `ρgh` at 0.2–0.3 m depth | ~2–3 kPa (0.02–0.03 bar) |

**Dynamic dominates by roughly an order of magnitude**, which reframes open decision 6: the
MS5837-30BA (0–30 bar absolute, 24-bit, ~2 mm depth resolution, I2C, gel-isolated) is a plausible
**speed** sensor, not only a depth sensor.

SWD cannot supply a measured value to check this against — its `dynamic_pressure_pa` field is one of
the 13 constant-zero columns the extractor drops. But `½ρV²` is available analytically at SWD's
recovered ρ = 1023 kg/m³ (tabulated, salt water at 30 °C), and the surrogate's force–speed relation gives a predicted stagnation
pressure the sensor could be calibrated against.

---

## 📂 8. Untapped libraries

The extractor reads **2 of the 14** `.fyn*` types in the library. Every type below opens with the same
BinaryFormatter header as `.fynbs` (`0001000000ffffffff010000`), so the existing deserialiser,
`AssemblyResolve` handler and provenance gate read them unchanged.

| Type | .NET class | Files | Fields of interest |
|---|---|---:|---|
| `.fynsurfr` | `SurfHydrodynamics.Class_surfeur` | **11** | `_poids_kg`, `_taille_metre`, `_niveau`, `_endurence_secondes`, `_Paddle_impulse_force_newtons`, `_power_of_one_paddlle_move_w` |
| `.fynstat` | `SurfHydrodynamics.Class_fyns` | 7 | `_flex_vertical`, `_flex_horizontal`, `_surface_m2`, `_largeur_mm`, `_cambre_mm` |
| `.fyndyn` | `SurfHydrodynamics.Class_fyns` | 2 | as above (dynamic / ADAC fins) |
| `.fynvague` | `SurfHydrodynamics.vague` | 15 | `pente_deg_detection_crete`, `pente_deg_detection_defelement`, `nb_pt_echantillon` |
| `.fynlines` `.fyncoup` `.fyntail` `.fynrail` `.fyncplroc` | geometry | 14/14/11/6/10 | outlines, sections, tails, rails, rockers |

### 🔹 Surfer mass — a candidate axis, untested

The surfer library spans a deliberate range: `Surfer 65 kg`, `Surfer 95 kg`, `Surfer 7 / 10 / 14 / 17
years`, `Beginner` / `Medium` / `Experimented` / `Pro` / `default`. `Surfer Pro` reads **80 kg** live,
and the configuration panel displays `Displacement (board+surfer)`, so surfer mass enters the planing
solution.

Two reasons it is worth noting:

1. The hydroscan solves planing equilibrium, which depends on total weight, so scanning one board
   against two surfer masses **should** move the equilibrium attitude and therefore drag and lift.
   **This has not been tested.** One board × two surfers is roughly 24 minutes of scanning.
2. `m` is a paper symbol — it appears directly in `a_z = (F_lift − mg)/m` — so varying it is
   physically meaningful rather than an arbitrary knob.

### 🔹 Fin flex

`_flex_vertical` and `_flex_horizontal` are flex properties of the fin. The paper's `α` and `β` are
**board** flexion and torsion from strain gauges, so these are **not** the same quantity — but "SWD has
no flex data" would be too strong a statement.

### 🔹 Parametric geometry

`Apply Length`, `Apply Width` and `Apply Volume` are live controls with editable fields. One library
board was homothetically scaled 1800 → 2000 mm by exactly this route, so **designed geometry sweeps**
are possible — controlled and parametric — rather than relying on donated hulls.

---

## 📂 9. What none of this can establish

* **Speed dependence.** Every operating point sits at one velocity. No claim about behaviour at other
  speeds is supported by this data, whether or not V² scaling is adopted.
* **Turn-radius dependence.** Radius is per-board metadata, so radius and board identity are perfectly
  confounded. No model trained here can separate them.
* **Generalisation beyond the 14 scanned hulls.** The library holds 28 board rows carrying **27
  distinct (mass, volume, foam-mass) signatures** — `default_shortboard_Copy_2` and `Copy_3` are
  identical to full float precision, so scanning both would add pseudo-replication, not information.
* **Anything the paper's supplementary data covers.** It is one synchronised ~10 s window of one wave,
  one surfer, one board — a check on whether an indicator is *implemented* correctly, not evidence of
  generalisation. One of its 8 EMG channels is dead.
* **That SWD's physics is correct.** Nothing here validates the solver; it validates that the data was
  read faithfully and is internally consistent.

---

## 📂 10. Two defects in the supplied specifications

Recorded rather than silently corrected. Both documents are inputs to this project and are left
unedited.

1. **`mma3001-project-spec.md` Part 4 § 3** — the surrogate as specified is untrainable: one feature is
   constant, one target is board metadata (§ 3).
2. **`mma3001-project-spec.md` Part 4 § 2 vs the paper's Eq 7** — the specification defines the
   normalisation length `D` as `∫V dt`, the arc length. The paper defines it as the **double integral
   of acceleration**, i.e. net displacement. These are different quantities, and `D` enters the jerk
   cost squared through `C = T⁵/D²`. **Follow the paper.**
