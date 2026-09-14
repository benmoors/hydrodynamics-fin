# 📘 Performance Metrics Reference

### The Charles et al. (2026) indicator set, transcribed and audited

> **Status: internal working reference.** This is source material compiled from the published paper,
> not a report section and not a deliverable. **No indicator is implemented here** — there is no code
> in this file. The project report is written separately and is the author's own work. Nothing in this
> document is an AI acknowledgement or an academic-integrity statement.

Every equation, figure and table number below was read from the article PDF in the repository root on
2026-08-31. Every derived number was recomputed this session from the paper's own published values.
Where the paper disagrees with itself, or with its own supplementary data, this document says so
instead of choosing a resolution.

---

### 🎯 What this document settles

> * The paper defines **17 equations**, not the two the project spec names.
> * Which of them this project can compute, from where, and which are structurally out of reach.
> * The **published numbers for waves 4 and 5**, so an implementation has external targets rather than
>   only a plausible-looking output.
> * That **71 of 72** published relationships reproduce from the paper's own tables — and which one
>   does not.
> * Six discrepancies that an implementation would otherwise hit blind.

---

## 📂 1. Source and conventions

Charles, P-E., Algourdin, P., Ostre, B. et al. (2026). *A novel surfing performance quantification
system and multi-sensor instrumented surfboard: A proof-of-concept.* **Results in Engineering**
29:108868. DOI [10.1016/j.rineng.2025.108868](https://doi.org/10.1016/j.rineng.2025.108868).
CC BY 4.0. The PDF is in the repository root; the supplementary archives are in
`SWD/data/paper-supplementary/` with [`SOURCE.md`](../data/paper-supplementary/SOURCE.md).

### 🔹 Axes

**X roll · Y pitch · Z yaw**, board frame. Every rotation symbol in the paper follows this, so `R_z` is
yaw rate and `R_x` is roll rate. The phase boundaries depend on the roll axis and the radicality
indicator on the yaw axis, so mixing the two swaps the two headline indicators.

### 🔹 Instrumentation, and the rates each channel was captured at

| Channel | Hardware | Rate |
|---|---|---|
| Board IMU — `a_x a_y a_z`, `R_x R_y R_z` | Arduino Nano RP2040 Connect, **6-DoF, no magnetometer** | ~14.6 Hz mean, non-uniform |
| Board strain gauges — SG1…SG5 | 5 gauges, Wheatstone bridge + HX711 amplifier each | as above, same file |
| Surfer IMU (full body) | Cometa WaveTrack | 2000 Hz |
| Surfer EMG | Cometa MiniWave Infinity, SENIAM placement | 2000 Hz |
| Calibration reference IMU | MetaMotionS (MBientlab) | 100 Hz, Kalman gain 0.95 |

The board rate is measured from `Board_Sample.txt` rather than stated in the paper — see [`SOURCE.md`](../data/paper-supplementary/SOURCE.md)
§ 3, which also records that its time column runs **backwards** on its own epoch.

> ### 💬 Aside — the board IMU has no magnetometer
> The Arduino Nano RP2040 Connect carries a 6-DoF IMU. Every published `Ra` in § 8 was therefore
> obtained with **no absolute heading reference at all**. That is the direct evidence behind the
> magnetometer position in [`project-io-spec.md`](project-io-spec.md) § 7: a magnetometer is worth having for trajectory
> reconstruction, and radicality does not depend on one.

---

## 📂 2. The sensor layer — Equations 1 to 3

### 🔹 Eq 1 — strain gauge output

    V = V₀ + dV

`dV` depends on the deformation of the gauge's support. Read through a Wheatstone bridge per gauge,
amplified by an HX711 because `dV` alone is too small for the Arduino's ADC.

### 🔹 Eq 2 — tail flexion α

    (C₁F₁ + C₂F₂) / 2 = α

### 🔹 Eq 3 — tail torsion β

    (C₁F₁ − C₂F₂) / 2 = β

`C₁, C₂` are calibration factors and `F₁, F₂` the two **rear** gauge values. Adding isolates flexion,
subtracting isolates torsion. Only the two rear gauges take part; the three-gauge protocol is a
different measurement.

### 🔹 Calibration precision — the paper's Table 3

| Protocol | Gauges used | Measures | Symbols | In-lab precision | Usable in real conditions |
|---|---|---|---|---|---|
| 1. Three-point bending | three, as one tool | applied force and its position | `x, y, F` | x 1 % · y 13 % · F 13.5 % | **No** |
| 2. Clamp bench, flexion | rear two | tail bending angle vs middle | `α` | **24.6 %** | Yes |
| 3. Clamp bench, torsion | rear two | tail tilt angle vs middle | `β` | **8.9 %** | Yes |

Protocol 1 is excluded from real-condition use by the authors themselves: its three-point boundary
condition does not represent the stress a surfer applies. So the board's position-and-force output is a
laboratory result only.

---

## 📂 3. Primary indicators — Equations 4 to 11

Four indicators: **Board-Jerk**, **Surfer-Jerk**, **Muscle Activity**, **Radicality**. The first three
are quantities to *minimise*; radicality is the one to *maximise*, and the paper is explicit that
minimising jerk alone would reward a straight line.

### 🔹 Eq 4 — jerk

    j = da/dt

with `a(t) ∈ ℝ³` the acceleration vector.

### 🔹 Eq 5 — the jerk cost

    J = ∫₀ᵀ C · (j²/2) dt

`j²` is the squared magnitude of the jerk vector. `T` is the duration of the wave, measured from the
moment the surfer starts the take-off push to the moment their feet leave the board.

### 🔹 Eq 6 — the normalisation constant

    C = T⁵ / D²

Chosen to make `J` dimensionless. `C` is a constant over the integral, so it can be factored out —
the paper writes it inside.

### 🔹 Eq 7 — D

    D = √[ (∫₀ᵀ∫₀ᵀ a_x dt dt)² + (∫₀ᵀ∫₀ᵀ a_y dt dt)² + (∫₀ᵀ∫₀ᵀ a_z dt dt)² ]

**This is the magnitude of net displacement**, not path length: acceleration integrated twice, then the
three components combined at the endpoint. See § 10.1 — this single definition is the project's known
specification defect, and the paper's own prose is where it came from.

### 🔹 Eq 8 and 9 — muscle activity

    A_muscle = A_right + A_left                          (8)
    Σ = ∫₀ᵀ (A_TD + A_TB + A_BF + A_GM) dt               (9)

Four bilateral muscle pairs: **T**rapezius **D**escendens (upper), **T**riceps **B**rachii,
**B**iceps **F**emoris, **G**astrocnemius **M**edialis. `T` is the duration of the phase under
consideration, so `Σ` is computed per phase as well as per wave.

### 🔹 Eq 10 — swept angle

    θ_z = ∫_{t₀}^{t₁} R_z dt

`t₀` and `t₁` are the start and end of the top-turn maneuver, defined as the moments the board reverses
its rotation direction about the X axis — **`R_x(t₀) = R_x(t₁) = 0`**.

### 🔹 Eq 11 — Radicality

    Ra = θ_z · R̄_z = θ_z² / (t₁ − t₀)

`R̄_z` is the mean yaw rate between `t₀` and `t₁`. Larger means more radical. The two forms are
algebraically identical given Eq 10, which makes Eq 11 self-checking — and § 9 uses that.

### 🔹 Signal processing — required, and recorded nowhere else in this repository

| Signal | Treatment |
|---|---|
| Surfer IMU acceleration | 4th-order **Butterworth lowpass, 7 Hz** cutoff |
| EMG | 4th-order **Butterworth bandpass, 20–400 Hz**, then **RMS with a 300 ms sliding window** |
| Board data | no filter specified in the paper |

> ### ⚠️ Point of note — filtering is not a detail here
> Jerk is the **third** derivative of position. Each differentiation amplifies high-frequency noise, so
> the cutoff chosen upstream sets the magnitude of everything downstream. Two implementations that
> differ only in filter choice will not produce comparable `J`. The 7 Hz figure is the paper's, and any
> departure from it should be stated rather than absorbed.

---

## 📂 4. Discriminators — Equations 12 to 16

Five combination models. The first four describe the top turn; the last describes the whole wave.

| Eq | Name | Definition | Meaning |
|---|---|---|---|
| 12 | Raw discrimination | `D_raw,I = I_Top / Ra` | indicator against radicality, unnormalised |
| 13 | Bottom-turn normalisation | `I_N = I_Top / I_Bottom` | top turn against the bottom turn that set it up |
| 14 | Bottom-normalised discrimination | `D_B,I = I_N / Ra` | Eq 13 against radicality |
| 15 | Muscle-activity discrimination | `D_MA,J = MA_N / J_N` | surfer effort against sudden movement |
| 16 | **Piloting Ratio** | `PR = SJ / BJ` | surfer against board |

`I` is any indicator; `J` is any jerk indicator.

**Piloting Ratio reads directly:** `PR = 1` means the surfer is in phase with the board's reaction.
`PR > 1` or `PR < 1` both indicate a combination that made piloting difficult. It applies to a whole
wave or to a single phase.

> ### ⚠️ Point of note — Eq 12's units do not permit cross-comparison
> The paper states it plainly: *no comparison must be made between the MA discriminator value and a
> jerk-based discriminator value.* `D_raw,MA` and `D_raw,BJ` are different physical quantities that
> happen to share a formula. Table 5's rows are not a ranking.

---

## 📂 5. Mechanical coupling — Equation 17

    MI = M / I

`M` is a mechanical behaviour, either **flexion displacement FD** in mm or **torsion angle TA** in rad.
`I` is any indicator or discriminator. The authors offer these ratios as a future tool for relating
board construction to performance, not as a validated result — they state repeated experiments are
required before the ratios mean anything.

---

## 📂 6. Phase decomposition

Five phases: **paddling · take-off · trimming · bottom turn · top turn**.

Paddling is taken as the 3 s before take-off. The bottom turn and top turn are treated as inseparable,
because the top-turn trajectory depends on the bottom turn that set it up — which is the entire
justification for Eq 13's normalisation.

Maneuver boundaries are **`R_x(t) = 0` sign changes**, roll-rate zero crossings.

### 🔹 Wave 4 phase breakdown, as published

| Phase | Duration | Share of muscle activity |
|---|---:|---:|
| Paddling | 2.4 s | 41.3 % |
| Take-off | 0.5 s | 15.0 % |
| Trimming | 2.2 s | 25.0 % |
| Bottom turn | 0.5 s | 7.5 % |
| Top turn | 0.8 s | 11.2 % |

Dividing activity share by duration gives relative muscle activity, and on that measure **take-off is
the most demanding phase despite being the shortest** — which the authors note matches what elite
coaches report.

### 🔹 The five recorded waves

| Wave | Duration | Side | Maneuver | Surfer instrumented |
|---|---:|---|---|:--:|
| 1 | 4.5 s | right, backside | floater | ✗ |
| 2 | 4.6 s | right, backside | carve | ✗ |
| 3 | 6.6 s | right, backside | re-entry | ✗ |
| **4** | **5 s** | left, frontside | re-entry, ending in a fall | **✓** |
| **5** | **7.7 s** | left, frontside | completed carve | **✓** |

Only waves 4 and 5 carry surfer instrumentation, which is why every published indicator table covers
those two and no others.

---

## 📂 7. Availability — where each quantity can come from

Three sources: **SWD** (simulated board hydrodynamics), the **supplementary archives** (one measured
10 s window), and neither.

| Eq | Quantity | SWD | Supplementary | Note |
|---|---|:--:|:--:|---|
| 1 | Strain gauge `V` | ✗ | ✓ | `SG1…SG5` in `mmc1` |
| 2, 3 | Flexion α, torsion β | ✗ | ✓ | needs the gauge calibration factors |
| 4 | Jerk `j` | ✓ derived | ✓ measured | SWD path needs a trajectory |
| 5, 6, 7 | `J`, `C`, `D` | ✓ derived | ✓ measured | |
| — | **Board-Jerk** | ✓ derived | ✓ measured | |
| — | **Surfer-Jerk** | ✗ | ✓ | needs the surfer's lower-back IMU |
| 8, 9 | `A_muscle`, `Σ` | ✗ | ⚠️ partial | one channel dead — § 10.4 |
| 10, 11 | `θ_z`, `R̄_z`, **Radicality** | ✓ derived | ✓ measured | `R_z = V/R` from the trajectory |
| 12 | `D_raw,I` | ✓ for BJ | ✓ all | |
| 13, 14 | `I_N`, `D_B,I` | ✓ for BJ | ✓ all | needs a phase-segmented trajectory |
| 15 | `D_MA,J` | ✗ | ⚠️ partial | inherits the MA gap |
| 16 | **Piloting Ratio** | ✗ | ✓ | needs both jerks on one clock — § 10.5 |
| 17 | `MI` | ✗ | ✓ | needs FD and TA |
| — | Lift/drag, minimum-drag attitude, manoeuvrability envelope | ✓ | ✗ | SWD only; no paper equivalent |

**"✓ derived" means SWD supplies the forces and a trajectory model supplies the kinematics.** SWD is a
force model, not a kinematics model — it answers what forces act on a hull at an attitude. The bridge
is `a_x = dV/dt`, `a_y = V²/R`, `a_z = (F_lift − mg)/m`, `R_x = dφ/dt`, `R_z = V/R`.

Column-level detail — data types, units, operating ranges, invalid-value handling — lives in
[`project-io-spec.md`](project-io-spec.md) and is not repeated here. The archives' internals are in
[`SWD/data/paper-supplementary/SOURCE.md`](../data/paper-supplementary/SOURCE.md).

---

## 📂 8. Validation targets

The paper's published results for waves 4 and 5. These are the external targets an implementation can
be measured against.

### 🔹 Table 4 — Radicality

| | Wave 4 | Wave 5 |
|---|---:|---:|
| Mean rotation speed `R̄_z` (rad/s) | 2.94 | 1.48 |
| Swept angle `θ_z` (rad) | 1.66 | 2.04 |
| **`Ra` (rad²/s)** | **4.89** | **3.02** |

### 🔹 Table 5 — raw discriminators

| | Wave 4 | Wave 5 |
|---|---:|---:|
| `Ra` | 4.89 | 3.02 |
| `D_raw,MA` | 49.24 | 189.95 |
| `D_raw,SJ` | 11.32 | 20.59 |
| `D_raw,BJ` | 14.81 | 44.35 |

### 🔹 Table 6 — bottom-normalised

| | Wave 4 | Wave 5 |
|---|---:|---:|
| `MA_N` | 1.00 | 1.69 |
| `SJ_N` | 1.02 | 1.58 |
| `BJ_N` | 1.28 | 1.77 |
| `D_B,MA` | 0.20 | 0.56 |
| `D_B,SJ` | 0.21 | 0.52 |
| `D_B,BJ` | 0.26 | 0.59 |

### 🔹 Table 7 — muscle-activity discriminators

| | Wave 4 | Wave 5 |
|---|---:|---:|
| `D_MA,SJ` | 0.98 | 1.07 |
| `D_MA,BJ` | 0.79 | **0.89** |

The wave 5 value is the one relationship in the paper that does not reproduce — § 9 and § 10.2.

### 🔹 Table 8 — per-phase jerks and Piloting Ratio

| Wave | Phase | Surfer-Jerk | Board-Jerk | `PR` |
|---:|---|---:|---:|---:|
| 4 | Take-off | 93.14 | 60.97 | 1.53 |
| 4 | Trimming | 155.02 | 174.62 | 0.89 |
| 4 | Bottom turn | 54.21 | 56.32 | 0.96 |
| 4 | Top turn | 55.33 | 72.34 | 0.76 |
| 4 | End | 122.18 | 96.23 | 1.27 |
| **4** | **Full wave** | **479.87** | **460.47** | **1.04** |
| 5 | Take-off | 48.91 | 90.13 | 0.54 |
| 5 | Trimming | 200.46 | 401.50 | 0.50 |
| 5 | Bottom turn | 39.31 | 75.41 | 0.52 |
| 5 | Top turn | 62.09 | 133.73 | 0.46 |
| 5 | End | 40.20 | 91.52 | 0.44 |
| **5** | **Full wave** | **390.97** | **792.28** | **0.49** |

Wave 4 sits near `PR = 1` throughout; wave 5 sits near 0.5 in every phase. The paper reads that as
wave 4 being the better-matched surfer-board-wave combination.

Note that Table 8 carries a sixth phase, **"End"**, which does not appear in the five-phase
decomposition of § 6.

### 🔹 Table 9 — MI ratios, top turn

Mechanical values: wave 4 `FD = −0.60 ± 0.15` mm, `TA = 0.11 ± 0.01` rad; wave 5 `FD = −0.10 ± 0.02` mm,
`TA = −0.06 ± 0.005` rad.

| `I` | W4 FD | W4 TA | W5 FD | W5 TA |
|---|---:|---:|---:|---:|
| `Ra` | −0.123 | 0.023 | −0.033 | −0.020 |
| `D_raw,MA` | −0.012 | 0.002 | −0.001 | 0.000 |
| `D_raw,SJ` | −0.053 | 0.010 | −0.005 | −0.003 |
| `D_raw,BJ` | −0.041 | 0.007 | −0.002 | −0.001 |
| `D_B,MA` | −2.945 | 0.540 | −0.179 | −0.107 |
| `D_B,SJ` | −2.872 | 0.527 | −0.191 | −0.115 |
| `D_B,BJ` | −2.282 | 0.418 | −0.170 | −0.102 |
| `D_MA,SJ` | −0.615 | 0.113 | −0.093 | −0.056 |
| `D_MA,BJ` | −0.755 | 0.138 | −0.112 | −0.067 |
| `PR_top` | −0.784 | 0.144 | −0.215 | −0.129 |

> ### ⚠️ Point of note — do not read Table 9 out of the PDF's text layer
> Automated text extraction **drops the decimal comma** in this table only: `−0,123` comes out as
> `−0123`, three orders of magnitude wrong and entirely plausible-looking. Every value above was
> reconstructed as `M / I` from Tables 4–8 and verified against the extracted digits — **40 of 40 cells**,
> both waves, both mechanical measures. Anyone re-reading this table should reconstruct rather than parse.

---

## 📂 9. Self-consistency audit

Equations 11 to 17 form a closed system: Table 8's per-phase jerks generate Tables 5, 6 and 7, and
Tables 4–8 generate Table 9. Every such relationship was recomputed this session.

**Result: 71 of 72 reproduce.**

| Relationship | Checks | Result |
|---|---:|---|
| Eq 11 — `Ra = θ_z · R̄_z` | 2 | ✅ 4.880 vs 4.89 · 3.019 vs 3.02 |
| Eq 12 — `D_raw,I = I_Top/Ra` from Table 8 | 4 | ✅ |
| Eq 13 — `I_N = I_Top/I_Bottom` from Table 8 | 4 | ✅ |
| Eq 14 — `D_B,I = I_N/Ra` within Table 6 | 6 | ✅ |
| Eq 15 — `D_MA,J = MA_N/J_N` | 4 | ⚠️ **3 of 4** |
| Eq 16 — `PR = SJ/BJ`, all phases and full wave | 12 | ✅ |
| Eq 17 — `MI = M/I` against Tables 4–8, every cell | 40 | ✅ |
| | **72** | **71 pass, 1 fail** |

Worked examples, so the method is checkable rather than asserted:

    Eq 12, wave 5:   BJ_Top / Ra   =  133.73 / 3.02  =  44.28    published 44.35   ✅
    Eq 13, wave 5:   BJ_Top / BJ_Bot = 133.73 / 75.41 =  1.7734   published  1.77   ✅
    Eq 14, wave 4:   BJ_N / Ra     =    1.28 / 4.89  =   0.2618   published  0.26   ✅
    Eq 16, wave 4:   SJ / BJ       =  479.87 / 460.47 =  1.0421   published  1.04   ✅
    Eq 17, wave 4:   FD / D_B,MA   =   −0.60 / 0.2045 = −2.934    published −2.945  ✅

Residuals throughout are consistent with the published values having been rounded before printing —
two decimals in Tables 4–8, three in Table 9. The audit accepted a 3 % relative band on Tables 4–8 and
6 % on Table 9, where several published cells are small enough (0.000, 0.002) that the last printed
digit dominates.

> ### 💬 Aside — why this is worth the arithmetic
> Two published figures, `Ra` and `BJ`, are weak validation: an implementation can match them by
> coincidence or by tuning. Seventy-two internally consistent relationships are a different kind of
> target. An implementation that reproduces Table 8 gets Tables 5, 6, 7 and 9 for free — and if it
> does not, the failing row localises the error to one equation.

---

## 📂 10. Discrepancies

Six, all found by reading the paper against itself and against its own supplementary data. Each is
recorded rather than resolved.

### 🔹 10.1 — `D`: the paper's prose and its equation describe different quantities

Eq 7 computes the **magnitude of net displacement**. The sentence introducing it calls `D`
*"the length of the overall trajectory"* — path length, a different quantity. For any trajectory that
is not a straight line the two differ, and for a closed loop the first is zero while the second is not.

This propagates into the project's supplied specifications, and it is worth being precise about which
one is wrong:

| Document | Definition given | Agrees with paper's equation |
|---|---|:--:|
| Paper, Eq 7 | double integral of acceleration, magnitude | — |
| [`surfing-performance-io.md`](../../surfing-performance-io.md) line 26 and its code | double integral, endpoint magnitude | ✅ |
| [`mma3001-project-spec.md`](../../mma3001-project-spec.md) line 129 | `D = ∫₀ᵀ V(t) dt` | ❌ |

So the two supplied specs disagree with each other, and the paper sides with [`surfing-performance-io.md`](../../surfing-performance-io.md).
[`mma3001-project-spec.md`](../../mma3001-project-spec.md)'s reading is a faithful transcription of the paper's *sentence* — which is
most likely where it came from.

`D` enters `J` squared through `C = T⁵/D²`, so this is not a cosmetic difference. [`CLAUDE.md`](../../CLAUDE.md) § 7
directs following the paper's equation. **Neither spec file is edited** — both are supplied material.

Minor, and in the same area: the printed Eq 7 shows a single `dt` for what the surrounding text
describes as a double integral. [`surfing-performance-io.md`](../../surfing-performance-io.md) writes `dt dt`, silently correcting a
typesetting slip.

### 🔹 10.2 — Table 7's `D_MA,BJ` does not reproduce on wave 5

Eq 15 gives `D_MA,BJ = MA_N / BJ_N`. From Table 6:

    wave 5:   MA_N / BJ_N  =  1.69 / 1.77  =  0.955        published 0.89   ❌
    wave 4:   MA_N / BJ_N  =  1.00 / 1.28  =  0.781        published 0.79   inconclusive

The gap on wave 5 is far larger than rounding can explain: reaching 0.89 would need `MA_N = 1.575`
against a published 1.69, or `BJ_N = 1.899` against a published 1.77.

**An observation, offered as nothing more:** `SJ_N / BJ_N` reproduces both published values —
`1.58/1.77 = 0.893` on wave 5 and `1.02/1.28 = 0.797` on wave 4. Table 9's `D_MA,BJ` row confirms 0.89
is the value that was actually used downstream. What the authors intended is not something this
document can determine.

`D_MA,SJ` reproduces cleanly on both waves, so Eq 15 itself is sound.

### 🔹 10.3 — Radicality's implied duration disagrees with the published phase duration

Eq 11's two forms give `t₁ − t₀ = θ_z / R̄_z`:

| Wave | `θ_z` | `R̄_z` | Implied `t₁ − t₀` | Published top-turn duration |
|---:|---:|---:|---:|---:|
| 4 | 1.66 | 2.94 | **0.565 s** | **0.8 s** |
| 5 | 2.04 | 1.48 | **1.378 s** | not published |

The most likely reconciliation is that the muscle-activity phase window is broader than the `[t₀, t₁]`
that Eq 10 defines by roll-rate zero crossings — a phase and a maneuver are not obliged to be the same
interval. That is a plausible reading, not a resolved fact, and it matters: an implementation that
segments by one window and compares against numbers computed on the other will disagree with the paper
for a reason that has nothing to do with its arithmetic.

### 🔹 10.4 — the paper names a different hamstring muscle than its own data file ships

Eq 9 sums Trapezius Descendens, Triceps Brachii, **Biceps Femoris**, Gastrocnemius Medialis.
`EMG_Sample.txt` ships:

| Eq 9 term | Data file column | Match |
|---|---|:--:|
| `A_TD` | `R./L. Upper Trap.` | ✅ |
| `A_TB` | `R./L. Lat. Triceps` | ✅ |
| `A_BF` Biceps Femoris | `R./L. Semitend.` | ❌ **semitendinosus** |
| `A_GM` | `R./L. Med. Gastro` | ✅ |

Semitendinosus and biceps femoris are both hamstrings, and both are plausible SENIAM sites, but they
are not the same muscle.

**The same channel is also the dead one.** `L.Semitend.` holds the single value 3299.89917 across all
20,001 rows while every other channel has ~19,900 distinct values ([`SOURCE.md`](../data/paper-supplementary/SOURCE.md) § 3). So the `A_BF` term
of Eq 9 is both mislabelled relative to the paper and half-instrumented in the shipped sample. Any `Σ`
or `D_MA,J` computed from this data inherits that and should say so — **seven usable channels, not
eight.**

### 🔹 10.5 — the three archives are not on a common clock

`EMG_Sample.txt` and `IMU_Sample.txt` share an exact 225–235 s axis at 2000 Hz. `Board_Sample.txt` does
not: it is a board-side counter in milliseconds on its own epoch, running backwards, non-uniform at
67–89 ms. Full detail in [`SOURCE.md`](../data/paper-supplementary/SOURCE.md) § 3.

Piloting Ratio needs Surfer-Jerk and Board-Jerk on one clock. **The alignment is therefore an assumption
this project makes, not a measurement the authors published**, and every `PR` computed downstream
depends on it.

### 🔹 10.6 — wave 4's phase durations do not sum to its stated length

    paddling 2.4 + take-off 0.5 + trimming 2.2 + bottom 0.5 + top 0.8  =  6.4 s

against a wave described as **5 s**. Excluding paddling, which sits before take-off, gives 4.0 s.
Neither matches. `T` is defined as take-off to feet leaving the board.

Recorded without a proposed reconciliation. It affects `C = T⁵/D²`, where `T` enters at the fifth
power, so the choice of `T` is not a rounding-level decision: 4.0 s against 5 s is a factor of about
three in `C`.

---

## 📂 11. What this cannot establish

* **Two waves, one surfer, one board, one session.** The published indicator values in § 8 are a
  ground-truth check on whether an implementation computes the equations correctly. They are not
  evidence that any indicator measures surfing performance.
* **The authors' own limitation, which is stronger than that:** oceanic waves are unique and cannot be
  duplicated, and they state that **no conclusions on surfing performance should be drawn from the
  in-situ experiment alone**. The indicators are meaningful only between comparable waves, on the same
  board, with the most similar surfing possible.
* **The discriminators are proposals, not validated instruments.** The paper says repeated experiments
  are required to assess their accuracy and refine their physical meaning, and names `PR` as the
  priority for future work.
* **Board precision as published: 24.6 % flexion, 8.9 % torsion**, which the authors note is enough to
  cause overlap between different maneuvers' data. Nose behaviour is not measured at all.
* **Matching a published number is not validation of the physics.** Reproducing Table 8 shows the
  arithmetic is right. Whether an SWD-derived trajectory resembles a real one is a separate question
  this document does not touch, and the single-velocity limitation in [`project-io-spec.md`](project-io-spec.md) § 5 and
  [`what-swd-can-yield.md`](what-swd-can-yield.md) § 3 applies to every SWD-derived indicator.
* **Nothing here has been checked against the authors' own implementation.** Their Arduino, Matlab and
  Python scripts are available from the corresponding author on request ([`SOURCE.md`](../data/paper-supplementary/SOURCE.md) § 1). If a
  computed indicator ever disagrees with § 8, that is the reference to ask for.
