# 📘 SWD Data Acquisition

### Extracting hydrodynamic data from ShaperWaveDynamics for machine learning

ShaperWaveDynamics (SWD) is a commercial surfboard-hydrodynamics application with no CSV export and no
API. This component reads its binary project files directly and produces the tabular data the
"Virtual Surfer" surrogate model is trained on.

---

### 🎯 What this component does

> * Reads SWD's undocumented `.fyn*` binary format without launching or modifying the application.
> * Produces four CSV tables, one of which is the training table for the surrogate model.
> * States plainly which axes the data covers and which it does not, so the modelling downstream is
>   not built on a coverage assumption that does not hold.
> * Refuses to deserialise any file whose provenance has not been approved.

**Scope boundary.** This component stops at the CSVs. The surrogate model, Board-Jerk, Radicality and
the trajectory simulation are separate work and are not part of this directory.

---

## 📂 1. The engineering problem

Physics-based hydrodynamic solvers are slow. A single SWD hydroscan of one board takes over an hour,
which makes it unusable inside a loop. The Virtual Surfer project needs drag and turn-radius
predictions at 100 Hz along a simulated wave trajectory, so a machine-learning surrogate is trained on
a grid of SWD results and queried in place of the solver.

That surrogate needs training data, and SWD provides no way to export any. It writes only STL, PNG and
PDF; a string scan of the executable returns zero hits for `csv` or `Excel`. The problem this component
solves is therefore narrow and concrete: **get SWD's computed hydrodynamics out of its binary files and
into arrays, faithfully, without damaging the installation.**

### 🔹 Why fidelity matters more than convenience

The licence is machine-bound and was not cheap, and the board library is the only copy. An extraction
tool that corrupted either would cost more than the data is worth. Every design decision here favours
provable read-only behaviour over speed or ergonomics.

> ### ⚠️ Point of note
> The alternative routes were considered and rejected on evidence, not preference. The Mecaflux MCP
> server (`pass_mcp.php`) exposes **Heliciel only** — a different product — and is explicitly not a
> licence for anything already owned. Reimplementing SWD's on-disk format from scratch would be a
> large project and would still need validating against the real files. Driving SWD's GUI to use its
> own report export is possible in principle but is blocked on this machine (§ 6).

---

## 📂 2. Inputs and outputs

### 🔹 Inputs

| Input | Format | Notes |
|---|---|---|
| `.fynbs` board files | .NET `BinaryFormatter` graph of `Class_surfboard` | 27 files. Carries speed setting, turn radius, masses, volumes |
| `.fynrhydro` hydro reports | `BinaryFormatter` graph of `Class_rapport_hydrodynamique` | 132 files: 12 boards × 11 drift angles |
| `fyn_profile_data_base.xml` | XML, French locale | 26.9 MB fin-profile polar database |
| Trust manifest | JSON, SHA-256 per file | Machine-local, outside the repo |

**Invalid, missing and unsupported inputs** are handled explicitly rather than by exception:

- A file that fails to deserialise is counted as a parse failure, named in a warning, and skipped. The
  run continues and reports the count; it never silently produces a short table.
- A file absent from the trust manifest is refused before `BinaryFormatter` sees it, listed by relative
  path, and the summary states the tables are incomplete by exactly those files.
- A field that does not exist on the type is dropped with a warning rather than exported as zero.
- A field that is absent or null becomes `NaN`, never `0.0` — the two are not the same and conflating
  them is how a missing measurement becomes a fake one.
- An `-OutDir` resolving inside the install directory or the board library is refused outright.

### 🔹 Outputs

All four tables are UTF-8 **without BOM**, CRLF line endings, written together and vouched for by a
completion sentinel.

| File | Rows | Cols | Size | Role |
|---|---:|---:|---:|---|
| `operating_points.csv` | 667 | 19 | 0.2 MB | **training table** |
| `elements.csv` | 6,388 | 22 | 2.1 MB | spatial mesh — *not* independent samples |
| `boards.csv` | 27 | 10 | 4 KB | board metadata |
| `fin_polars.csv` | 680,400 | 7 | 48.3 MB | fin profile polars |
| `extract_manifest.json` | — | — | 3 KB | completion sentinel and provenance record |

**The four channels the surrogate needs**, all `float64`, all with zero missing values:

| Channel | Column | Unit | Observed range |
|---|---|---|---|
| Trajectory speed | `scan_speed_ms` | m/s | 20.00000 – 20.03910 |
| Roll angle | `roll_rad` | rad | −0.3738 – 1.3684 (per element: −0.7984 – 1.4909) |
| Turn radius | `turn_radius_m` | m | 19.08 – 100000 (9 distinct) |
| Drag force | `drag_total_n` | N | 157.4 – 522339.2 |

Also carried: `lift_total_n` (982 – 894,599 N) for the vertical acceleration term, `yaw_rate_rad_s`
(0.0002 – 1.0483, derived as `V / R`), drag broken into friction / planing / rail components, wetted
area, displaced volume and mass.

> ### ⚠️ Point of note
> **`scan_speed_ms` and `board_speed_setting_ms` are different quantities and must not be confused.**
> The first is the flow speed the hydroscan actually ran at, recovered from the planing mass balance.
> The second is the speed box in SWD's GUI as it stood when the board was last saved. They were
> assumed to be the same at first; they are not. See § 4.

---

## 📂 3. How the extraction works

`.fyn*` files are .NET `BinaryFormatter` graphs of SWD's own `[Serializable]` types. Rather than
reverse-engineering the byte layout, the extractor loads `SurfHydrodynamics.exe` **as a type library**
and lets .NET deserialise the files against the original classes. SWD is never launched.

This was chosen because the vendor's own type definitions are the ground truth for their own format:
there is no byte layout to guess at, and no drift if the format changes. The cost is a hard dependency
on Windows PowerShell 5.1, since `BinaryFormatter` was removed in .NET 9.

### 🔹 Assumptions

- SWD's installed assembly version can deserialise files stamped with older versions. Verified: reports
  are stamped `1.0.0.5`, the installed assembly is `1.0.8.1`, and all 132 parse.
- Serialised field values are the values SWD computed. Nothing is recomputed or interpolated.
- The board library is the user's own data and is approved before use (§ 5).

### 🔹 Known limitations

- Windows only, and Windows PowerShell 5.1 specifically.
- 36 of `element_hydrodynamique`'s 101 fields are `[NonSerialized]` and are simply not in the files.
  Both yaw-moment fields are among them, so yaw rate is derived kinematically rather than read.
- `BinaryFormatter` on untrusted input is a code-execution primitive. Mitigated, not eliminated (§ 5).

> ### 💬 Aside — four traps worth knowing about
> Each of these cost real time and is commented in the source so it is not rediscovered.
>
> **The assembly resolver must not recurse.** Reports request an assembly version that does not exist,
> so `AssemblyResolve` fires. A handler that calls `LoadFrom` inside itself re-enters and dies with an
> uncatchable `StackOverflowException`. It must return an already-loaded assembly.
>
> **`GetTypes()` throws** on this build. Use `GetType(name)`, or catch and filter.
>
> **Never string-interpolate a reference-typed field.** Formatting the cyclic object graph is a second
> route into the same stack overflow.
>
> **Field names carry French accents** (`_trainée_globale_horizontale_n`). They are built from explicit
> character codes so the source file's own encoding cannot corrupt them — the file is pure ASCII.

---

## 📂 4. Validation

Validation here answers one question: **do the numbers in the CSVs faithfully represent what SWD
computed?** That is a much narrower claim than "the physics is correct".

### 🔹 What was validated, and how

| Check | Method | Result |
|---|---|---|
| Every file parses | Full run over the library | 27/27 boards, 132/132 reports, **0 failures** |
| Nothing is silently lost | Parsed `<Table4>` blocks asserted against a raw text scan | **1890 / 1890**, terminating on mismatch |
| Determinism | Three independent full runs, SHA-256 compared | byte-identical |
| No fabricated data | Constant-zero column detector | 0 constant columns in any table |
| Encoding | Byte inspection of all outputs | no BOM, CRLF, zero non-ASCII |
| Numerical code | 133 Pester tests | 133 passed, 0 failed |
| Test quality | Mutation spot-check over changed code | 26/26 killed, 22 behaviourally |
| Containment | Behavioural runs against sandbox stand-ins | every protected path refused |

### 🔹 The physical cross-check that caught a real error

A physics identity caught what the tests did not. SWD's planing model deflects a stream of water, so
mass flux through the deflected section should satisfy `ṁ = ρ · A · V`. Recovering `V` from two
independently stored fields and comparing it against the board's recorded speed gives:

| Board's stored speed | Recovered flow speed |
|---:|---:|
| 2, 4, 5, 10, 12.96, 20 m/s | **20.000 m/s in every case, zero variance within each board** |

The stored speed is therefore *not* the scan condition. Two near-identical shortboards stored at 20 and
5 m/s differ in drag by 1.11×, where `V²` scaling would demand 16×, and the Spearman correlation
between stored speed and drag is **−0.15**. As a by-product, `ṁ/A` measures 20463.09 ± 10.68 kg/m²/s,
implying a seawater density of **1023.154 kg/m³** — recovered from the data rather than assumed.

Had this not been caught, the surrogate would have been trained against a feature that does not
describe the physics.

### 🔹 What this validation cannot establish

- **It says nothing about whether SWD's physics is right.** These are model outputs, not measurements.
  Extraction fidelity and physical accuracy are separate claims and only the first is evidenced here.
- **It cannot support any statement about speed dependence.** Every scan in the corpus ran at one
  speed, so the data contains zero information about how drag varies with velocity.
- **Generalisation across hull shapes is unsupported.** Twelve scanned boards is a small, non-random
  sample.
- **Behaviour at negative roll beyond −0.80 rad, and at negative turn radius, is absent entirely.**
- **The mutation score covers changed code only.** It is silent about untouched code, and a known
  fraction of mutants in any suite are equivalent and unkillable.
- **Determinism rests on three runs on one machine.** That bounds the risk rather than eliminating it.

### 🔹 Data-quality artefacts you must handle

These are SWD's own values, copied faithfully. They are not extraction errors.

| Artefact | Extent | Action |
|---|---|---|
| `Single.MaxValue` (3.4028e38) in `element_width_mm` | 58 of 5,914 rows | Filter `abs(x) > 1e30`. It does **not** reach the training table |
| Negative `cd` in `fin_polars.csv` | 12 of 680,400 rows | Filter `cd < 0`; drag coefficients cannot be negative |
| Constant-zero fields | 1 column in `boards.csv`, 13 in `elements.csv` | Already dropped at extraction and named in the manifest |

> ### ⚠️ Point of note
> **`elements.csv` rows are not independent samples.** They are the spatial mesh along one board at one
> condition. Training on them is pseudo-replication: near-duplicate rows straddle any random split and
> inflate R². Use `operating_points.csv`, and group any train/test split **by board**, because rows
> from one board share speed and radius exactly.

---

## 📂 5. Protecting the installation

The licence is machine-bound to a single registry value and the board library is 627 MB of irreplaceable
work. Three layers guard them.

**Read-only by construction.** Every write path resolves inside the output directory — there are exactly
two write sinks in the script and both are checked. The library is opened with `FileAccess::Read`. The
registry is never written. SWD's main window is never constructed, so no DirectX device is created and
the bundled network tool is never reached.

**Containment on the output directory.** An `-OutDir` resolving inside the install tree or the library —
or either of their parents — is refused. Comparison is canonical, so 8.3 short names, junctions and
`subst` drives cannot slip past, and extended-length, device and UNC paths are rejected outright.

**A provenance gate on deserialisation.** Nothing is deserialised unless its SHA-256 is in an approved
manifest. This matters because the usual "they are your own files" argument does not hold: the library
is cloud-synced and holds board files authored by seven different people, and unlike SWD — which opens
only what you ask it to — this tool globs the whole tree. A file that merely *arrived* would otherwise be
executed without anyone opening it.

```powershell
# once, when the library is believed clean
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "SWD\tools\swd_extract.ps1" -TrustCurrentLibrary

# every run after that
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "SWD\tools\swd_extract.ps1"
```

> ### ⚠️ Point of note
> The gate is **trust-on-first-use** and does **not** make `BinaryFormatter` safe. It detects change and
> new arrivals after a baseline; it does not validate the baseline, and a hostile file built only from
> approved types is still deserialised. Full reasoning and limits in
> [`docs/provenance-gate.md`](docs/provenance-gate.md).

---

## 📂 6. Coverage, and what is still missing

The corpus is large enough to fit a model and too narrow to generalise from.

**Volume is not the constraint.** Loeppky, Sacks and Welch (*Technometrics*, 2009) put the floor for an
initial computer experiment at roughly ten times the input dimension — about 20 runs for two features.
There are 667 operating points, some thirty times that, and a 20 % holdout leaves 133 test points.

**Coverage is the constraint.** All **143** scans ran at one speed and nine radii, on 13 of 27
boards. The first scan driven through this project's own automation (2026-08-28) added 11 reports
and a 13th board, but ran at the loaded ~20 m/s, so it widened the sample of hulls without touching
the speed axis. It did settle one thing: **turn radius is stored per board, not per operating
point** — constant within 13 of 13 scanned boards — so it is a board identifier, not a feature.

| Axis | Target | Actual | Status |
|---|---|---|---|
| Drag | measured | 157 – 522,339 N | ✅ |
| Roll | [−π/3, π/3] | −0.798 – 1.491 rad per element | ⚠️ negative side short by ~0.25 rad |
| Speed | open | **one value, 20.000 m/s** | ❌ no variation |
| Turn radius | varied | 9 values, no negatives | ⚠️ thin |

**Closing the gap requires running SWD's own HydroScan**, which is GUI-only. Scanning the 15 unscanned
boards would add roughly 660 operating points at (speed, radius) combinations not currently present,
including the only three negative radii in the library — the opposite turn direction, which is what
would fill the missing negative-roll side.

That work is specified but not done. Automating it is currently blocked by an OS-level input block on
this machine, diagnosed and written up in [`docs/phase2-hydroscan.md`](docs/phase2-hydroscan.md), which
also records what was learned about SWD's UI so the attempt can resume without repeating it.

---

## 📂 7. Reproducing this

**Requirements:** Windows, Windows PowerShell 5.1 (**not** `pwsh` 7+ — `BinaryFormatter` was removed in
.NET 9), a licensed SWD installation, Python 3 with pandas for the checks, Pester 6 for the tests.

```powershell
# extract (about 80 seconds)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "SWD\tools\swd_extract.ps1"

# tests
cd SWD\tools\tests
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\run_pester.ps1" ".\swd_extract.Tests.ps1"
```

The test suite stages a SHA-256-verified copy of the script into a temporary directory and runs against
that, so the suite can execute the real code without any risk to the live tool or the shipped dataset.

```
SWD/
├── README.md                     this document
├── TODO.md                       running progress log
├── tools/
│   ├── swd_extract.ps1           the extractor (1,195 lines)
│   ├── tests/                    133 Pester tests + mutation harness
│   └── phase2/swd_ui.ps1         GUI helper for the HydroScan work (see docs)
├── data/                         the four CSVs, coverage report, manifest
└── docs/
    ├── provenance-gate.md        the BinaryFormatter gate: design, limits
    └── phase2-hydroscan.md       HydroScan automation: findings and blocker
```

---

## 🤖 AI Acknowledgment

**What AI was used.** Claude Opus 5, via Claude Code (Anthropic), accessed 26–27 August 2026. Work
proceeded over several sessions. The extractor went through four substantive revisions: an initial
implementation, then three rounds of an adversarial review-and-fix cycle in which separate reviewer
agents audited the code and a separate agent applied fixes, with an independent verifier confirming each
round rather than the fixer certifying its own work. Known biases: a language model tends toward
confident phrasing regardless of evidential strength, and toward reporting a task as complete at the
first plausible stopping point. Both showed up here and are described below.

**How AI was used.** AI did the following: reverse-engineered the undocumented `.fyn*` format by
reflecting over SWD's assembly; located the HydroScan feature in the assembly's method table; wrote the
extractor, the 133-test Pester suite and the mutation harness; ran the adversarial review rounds; and
drafted this documentation. I directed the work throughout — I set the scope to data acquisition only,
required an SQA pass before anything touched the software, required that the process not corrupt the
installation, insisted the search for existing data be exhaustive rather than assumed, and required the
`BinaryFormatter` gate be fixed rather than left as a proposal. Where AI proposed something I judged
wrong or out of scope, it was not adopted.

**Human oversight and responsibility.** Outputs were verified rather than accepted. Every headline
number in this document was re-derived from the artifacts by a party other than the one that produced
them. The full extraction was run three times and compared byte-for-byte. Containment was tested
behaviourally against sandbox stand-ins rather than argued from the source. Where a claim could not be
verified it is marked as such, and § 4 states explicitly what the validation cannot establish.

**Errors the AI made, which is the part worth recording.** Four are material:

1. It concluded that trajectory speed and turn radius were absent from the data, having sampled a single
   board and read `[NonSerialized]` fields deserialising to zero as real zeros. Measuring all 27 boards
   overturned it.
2. Its fin-polar parser silently discarded **half** the database — every second XML block — and reported
   the truncated result as a success. The recovered half contained one profile and 23 Reynolds numbers
   present nowhere else.
3. It exported 13 columns that were identically zero across all 5,914 rows, in a script whose own
   comments claimed to prevent exactly that.
4. It reported a 7.9 % performance improvement that was not a measurement: the correctness fix in (2)
   changed what the program computed, invalidating the baseline the comparison rested on. Restated as no
   delta.

Items 2 and 3 were silent failures that the run's own "0 failures" summary actively concealed, and both
were caught by adversarial review rather than by testing. Item 4 is the classic case of a different
computation being reported as a faster one. A fifth error — a claim that a directory search had returned
nothing, when the search had been pointed at the wrong directory — was caught when a reviewer checked the
claim rather than the reasoning. These are recorded because the pattern matters more than the individual
bugs: **plausible, confident, and wrong is the characteristic failure mode, and only independent
verification caught any of them.**

I am responsible for the contents of this repository and for the conclusions drawn from the data it
produces.
