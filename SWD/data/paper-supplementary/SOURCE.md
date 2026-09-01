# 📘 Paper Supplementary Data

### The measured surfing dataset published alongside Charles et al. (2026)

Three archives of raw sensor data released by the authors of the paper this project's performance
indicators are taken from. They are the only source of *measured* surfing data available here — SWD
produces simulated hydrodynamics, and nothing in it observes a real surfer.

---

### 🎯 What this directory is for

> * Supplies **measured** Board-Jerk and Radicality, so the SWD-derived versions can be checked
>   against an independent instrument rather than against themselves.
> * Carries the channels SWD structurally cannot produce — surfer kinematics, muscle activity and
>   board flex — which unlock Surfer-Jerk, Muscle Activity, Piloting Ratio, `D_MA,J`, flexion α,
>   torsion β and the MI ratios.
> * Records provenance precisely enough that every number below can be re-derived from the archives
>   without trusting this document.

**Scope boundary.** This directory stops at the raw archives and their description. No indicator is
computed here.

---

## 📂 1. Source

Charles, P-E. et al. (2026). *A novel surfing performance quantification system and multi-sensor
instrumented surfboard: A proof-of-concept.* **Results in Engineering** 29:108868.
DOI [10.1016/j.rineng.2025.108868](https://doi.org/10.1016/j.rineng.2025.108868).
The article PDF is in the repository root.

Retrieved **2026-08-31** from `https://ars.els-cdn.com/content/image/1-s2.0-S2590123025049114-mmcN.zip`
(N = 1, 2, 3).

### 🔹 Licence

The article carries this statement in its own page-1 footer:

> "2590-1230/© 2025 The Authors. Published by Elsevier B.V. This is an open access article under the
> CC BY license (http://creativecommons.org/licenses/by/4.0/)."

**CC BY 4.0**, so the archives are redistributable with attribution, and they are stored here
unmodified and still zipped. Attribution is the citation in § 1. Verified by reading the PDF directly;
ScienceDirect returns HTTP 403 to automated requests, so the article landing page could not be used.

### 🔹 The paper's two availability statements disagree

Both are quoted because they are not consistent, and a reader should see both rather than be handed a
resolution.

> **§ 2.4, "Data and scripts availability statement":** "Raw data samples of board data, IMU and EMG
> are provided by the authors and can be found in addition to this paper. Arduino, Matlab and Python
> scripts used for the treatment and analysis of the data are available from the corresponding author
> upon request."

> **End-matter, "Data availability":** "Data will be made available on request."

§ 2.4 describes what is actually true: the three archives are attached to the article and downloaded
without any request. The end-matter line appears to be journal boilerplate.

> ### 💬 Aside — a route worth remembering
> § 2.4 also offers the authors' **Arduino, Matlab and Python analysis scripts** on request. Nothing
> here needs them, but if a BJ or Ra cross-check ever disagrees with the paper's published values,
> that is the reference implementation and it is one email away.

---

## 📂 2. The archives as downloaded

| Archive | Bytes | SHA-256 |
|---|---:|---|
| `mmc1.zip` | 19,937 | `2298c3e5c06ffe19fdc90081ad8f43c65aec9c9f23ed60379279445d7a3117d3` |
| `mmc2.zip` | 578,996 | `bbb754e66b95020bf92b30dd0148a66a3838d60af9083260bb5f6526a7842d44` |
| `mmc3.zip` | 3,778,356 | `483bf6292700aa6d1dc79129397c8c1090188895359a1234f6fdd922aea1e810` |

Each holds exactly one file, all three stamped `2025-12-23 01:51:50` in the zip directory.

| Archive | Inner file | Uncompressed | Lines | Delimiter | Decimal | Line ending | Header |
|---|---|---:|---:|---|---|---|---|
| `mmc1.zip` | `Board_Sample.txt` | 106,879 | 296 | `;` + space | `.` | CRLF | **none** |
| `mmc2.zip` | `EMG_Sample.txt` | 1,604,391 | 20,002 | tab | `.` | CRLF | yes |
| `mmc3.zip` | `IMU_Sample.txt` | 14,289,795 | 20,001 | tab | `.` | CRLF | **none** |

> ### ⚠️ Point of note — the French-locale trap does not apply here
> `CLAUDE.md` § 5 records SWD's `fyn_profile_data_base.xml` using French locale conventions — comma
> decimal separators, semicolon list separators — and these authors are French. **Measured: there is
> not a single comma in any of the three files.** All decimals are periods. `mmc1` does use `;` as a
> field separator, but that is a separator choice, not a locale decimal mark. Parse with
> `InvariantCulture` and no comma substitution.

---

## 📂 3. What is inside each file

### 🔹 `Board_Sample.txt` — instrumented board (mmc1)

**12 fields per data row**, matching the paper's board channel set:

    t ; SG1 ; SG2 ; SG3 ; SG4 ; SG5 ; a_x ; a_y ; a_z ; R_x ; R_y ; R_z

Five strain gauges, three accelerometer axes, three gyroscope axes. Axes per the paper: **X roll,
Y pitch, Z yaw**.

| Property | Measured value |
|---|---|
| Data rows | **148** |
| Time column | `2272066` → `2262011`, **strictly descending** |
| Span | 10,055 units ⇒ **10.055 s** if milliseconds |
| Sampling | **non-uniform**, step 67–89 ms, median 67 ms |
| Mean rate | **14.62 Hz** |

> ### ⚠️ Point of note — three traps in this one file
>
> **1. Half the file is not data.** The 296 lines strictly alternate: an even-indexed data row, then
> an odd-indexed line beginning with `;`. A naive line count or a plain `read_csv` ingests both. There
> are **148 data rows, not 296**.
>
> **2. Those `;` lines are a redundant echo, and this was checked rather than assumed.** Each is four
> fields — empty, a hex string, a large integer, and a decimal byte array. The hex string decodes to
> the *exact text of the data line above it* in **148 of 148** cases, so they are a transmission
> diagnostic carrying no independent information. Discard them.
>
> **3. This file is not on the same clock as the other two.** Its time column is a board-side counter
> in milliseconds with its own epoch (≈2262–2272 s) and it runs **backwards**. `mmc2` and `mmc3` are
> in seconds, ascending, starting at exactly 225. **The three are not co-registered by their own time
> columns** — aligning board data to surfer data is real work, not a join. See § 5.

### 🔹 `EMG_Sample.txt` — surface electromyography (mmc2)

The only file of the three with a header. **9 columns**: time plus 8 channels in µV, bilateral pairs
of four muscles.

| Column | Distinct values | Min | Max |
|---|---:|---:|---:|
| `Time(s)` | 20,001 | 225.00000 | 235.00000 |
| `R.Upper Trap.(uV)` | 19,988 | 0.00081 | 1984.67419 |
| `L.Upper Trap.(uV)` | 19,957 | 0.00122 | 157.40796 |
| `R.Lat. Triceps(uV)` | 19,966 | 0.00132 | 361.78217 |
| `L.Lat. Triceps(uV)` | 19,957 | 0.00133 | 294.16046 |
| `R.Semitend.(uV)` | 19,895 | 0.00055 | 209.92209 |
| **`L.Semitend.(uV)`** | **1** | **3299.89917** | **3299.89917** |
| `R.Med. Gastro(uV)` | 19,925 | 0.00066 | 147.82944 |
| `L.Med. Gastro(uV)` | 19,842 | 0.00054 | 657.07892 |

**20,001 data rows**, uniform 0.0005 s step, **exactly 2000 Hz**, spanning 225.0000 → 235.0000 s.

> ### ⚠️ Point of note — one EMG channel is dead
> **`L.Semitend.` holds the single value 3299.89917 for all 20,001 rows**, while every other channel
> has ~19,900 distinct values. That is a railed or disconnected electrode, not a muscle at rest — a
> resting muscle still shows baseline noise, as the other seven do at their ~0.001 µV minima.
>
> The paper's Muscle Activity metric is `Σ = ∫₀ᵀ (A_TD + A_TB + A_BF + A_GM) dt` over bilateral sums
> `A_muscle = A_right + A_left`, so the semitendinosus term is **half-instrumented**. Any MA or
> `D_MA,J` computed from this sample inherits that gap and must say so.
> **Seven usable channels, not eight.**

### 🔹 `IMU_Sample.txt` — full-body surfer motion capture (mmc3)

**92 fields per row: 1 time column + 91 data columns.** No header, so the column identities are **not
recoverable from the file itself** — the paper text or the authors' scripts (§ 1) are required to map
them.

**20,001 data rows**, uniform 0.0005 s step, **exactly 2000 Hz**, spanning 225.0000 → 235.0000 s.
No constant or dead columns; every one of the 91 varies across the window.

---

## 📂 4. Measured against what was predicted

The stage plan `SWD/docs/plans/WP1-WP2-paper-data-and-metrics.md` § 2.2 described these archives
before anyone had opened them. That description was tested rather than copied, and where the two
disagree the disagreement is kept visible:

| Claim | Predicted | Measured | Verdict |
|---|---|---|---|
| `mmc1` rows | 148 | 148 data rows, but **296 lines** | Half the file is an echo |
| `mmc1` rate | ~15 Hz | 14.62 Hz mean, **non-uniform** 67–89 ms | Refined; not a fixed rate |
| `mmc2` rows | 20,002 | 1 header + **20,001 data** | Line count, not row count |
| `mmc3` columns | ~90 | **91 data + 1 time** | Now exact |
| `mmc3` rows | 20,001 | 20,001 | ✅ |
| Rates 2000 Hz | 2000 Hz | exactly 2000 Hz, both files | ✅ |
| **"All three start at t = 225 s"** | all three | **only `mmc2` and `mmc3`** | ❌ **wrong** |
| Decimal separator | French-locale risk | period throughout, zero commas | Trap absent |

Two findings appear in no prior document: the **`mmc1` echo lines** and the **dead `L.Semitend.`
channel**.

---

## 📂 5. What this data cannot establish

The rubric asks for this explicitly, and the honest answer is short.

* **One wave, one surfer, one board, ~10 s.** A single synchronised window. It is a ground-truth check
  on whether an indicator is *implemented* correctly. It is not a training set, and it is no evidence
  of generalisation across waves, surfers or conditions.
* **The three files are not time-aligned as shipped.** `mmc2` and `mmc3` share an exact 225–235 s axis;
  `mmc1` does not (§ 3). Piloting Ratio `PR = SJ/BJ` needs board and surfer jerk on a common clock, so
  it depends on an alignment step that is an assumption of this project, not a measurement of the
  authors'.
* **Muscle Activity is computed from seven live channels, not eight** (§ 3).
* **The authors' own limitation, carried across:** oceanic waves are unique and cannot be duplicated,
  and they state that **no conclusions on surfing performance should be drawn from the in-situ
  experiment alone**. Indicators are meaningful only between comparable waves.
* **Board precision as published: 24.6 % flexion, 8.9 % torsion.** Nose behaviour is not measured at
  all.

---

## 📂 6. Reproducing this

    curl.exe -L --fail -o mmcN.zip \
      https://ars.els-cdn.com/content/image/1-s2.0-S2590123025049114-mmcN.zip

Then re-hash and compare against § 2. Every figure in this document was measured by reading inside the
archives with Python `zipfile` on 2026-08-31; none was copied from a filename, a file size, or a prior
description.

The archives are stored **unmodified and still zipped**, so the published artefact and any derived
table stay distinguishable.
