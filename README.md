# 📘 Virtual Surfer — a surfboard's speed and jerk cost from SWD's forces

MMA3001 Numerical Methods and Machine Learning — individual project.

A physics-based hydrodynamic solver (ShaperWaveDynamics, "SWD") gives the forces on a surfboard at a
fixed attitude, but no trajectory. It never says how fast a board travels down a wave face, or how
smoothly. This repository supplies that missing step. It:

- builds the friction drag on the board's bottom from boundary-layer theory;
- adds SWD's own planing and rail drag from its live solver;
- integrates the board's speed along the face with RK4;
- scores the run with the jerk cost of Charles et al. (2026), a smoothness measure from their
  surfing-performance study.

An earlier stage of the project, a machine-learning surrogate trained on SWD's output, is kept and
reported too, including where it fails.

The equations the code implements are the author's derivations. Each is recorded, with the choices
behind it, in [`AI-USE.md`](AI-USE.md) § 4.

---

## 📂 1. What is in here

    HYDRODYNAMICS-FIN/
    ├── src/
    │   ├── friction/                 friction drag F_f(V) on the board bottom
    │   │   ├── blasius_shooting/     Blasius by RK4 shooting, a central-difference check,
    │   │   │                         the layer thicknesses and the skin friction
    │   │   ├── von_karman/           the Kármán momentum integral, Majdalani–Xuan quartic
    │   │   ├── friction_force.py     F_f(V) on the live solver's wetted area and length
    │   │   └── rerun_live_screen_ff.py   Gate B: the second screen re-run with F_f
    │   ├── forward_model/
    │   │   ├── forward_model.py      V(t) down the face: the author's E15 and E16, by RK4
    │   │   └── board_jerk.py         the jerk cost J, Charles et al. Eq 4–7
    │   ├── swd_model/                two identifiability screens, and the superseded trajectory model
    │   └── geometry.py, data.py, splits.py, models.py, physics_baseline.py,
    │       evaluate.py, predict.py, profiling.py      the earlier surrogate
    ├── tests/                        pytest: 318 pass, 1 expected failure
    ├── docs/                         pdoc HTML, generated
    ├── SWD/                          the data acquired from SWD, and its documentation (section 6)
    ├── tools/                        regenerates the prompt appendix in AI-USE.md
    ├── AI-USE.md                     the AI-use record (section 8)
    ├── AGENTS.md, GEMINI.md          instructions for the agy and Devin reviewers
    └── requirements.txt, pyproject.toml

Every folder under `src/` is a Python package, so modules import each other as
`from src.friction import friction_force`. The Jupyter notebooks sit beside the modules they
exercise, in `src/friction/blasius_shooting/` and `src/friction/von_karman/`.

**`src/` and `SWD/` are separate on purpose.** `SWD/` holds what was taken out of a licensed
third-party application. `src/` is the modelling. Code in `src/` writes only into the `computed-data/`
folders under `SWD/data/`, and never into the extracted CSVs.

---

## 📂 2. Setup

Python **3.12 or newer** (developed on 3.14.6). No virtual environment is assumed.

```bash
pip install -r requirements.txt
```

| Package | Why |
|---|---|
| numpy, pandas | array and table handling |
| scipy | PCHIP interpolation, Simpson's rule, root-finding, least squares |
| scikit-learn ≥ 1.9 | SVR, decision tree, k-NN, pipelines, metrics (the surrogate) |
| matplotlib | the screens' figures and the notebooks' plots |
| pytest | the test suite |
| pdoc | HTML API documentation |

> ### 🧩 Point of note
> scikit-learn needs a wheel built for your interpreter. On Python 3.14 that means
> **scikit-learn 1.9.0 or later** — earlier releases have no `cp314` wheel and `pip` will
> fall back to a source build that requires a C++ toolchain.

Run everything from the repository root. The modules are a package, so a script runs as
`python -m src.<package>.<module>`, not by its file path.

### 🔹 Optional: Obsidian and Claude Code

The repository root is also an Obsidian vault. Project notes link to each other with relative
Markdown links, and the worklist is a Base (`SWD/docs/worklist/worklist.base`). Claude Code's memory
for this project lives in `memory/`, which is local and gitignored. None of this is needed to run the
code.

1. Clone the repository.
2. Install Obsidian **1.12.7 or newer from the installer**. The in-app updater does not create
   `Obsidian.com`, which the command-line interface needs on Windows.
3. Open the repository folder as a vault and allow community plugins.
4. Settings → General → **Command line interface** → Register, then restart the terminal.
5. Enable the **Local REST API** community plugin. In its settings, turn on the non-encrypted
   HTTP server on `127.0.0.1:27123`. Copy the API key into a user environment variable, then
   restart the terminal:

   ```powershell
   [Environment]::SetEnvironmentVariable('OBSIDIAN_API_KEY', '<key>', 'User')
   ```

6. Point Claude Code's memory at your own clone. Run this from the repository root:

   ```powershell
   New-Item -ItemType Directory -Force memory | Out-Null
   [IO.File]::WriteAllText("$PWD\.claude\settings.local.json", '{"autoMemoryDirectory": "' + ((Resolve-Path memory).Path -replace '\\','/') + '/"}')
   ```

7. Start `claude`, trust the folder, and approve the `obsidian` MCP server when asked.

> ### 🧩 Point of note
> Sync the vault with git, not Obsidian Sync. Every collaborator on a Sync shared vault needs
> their own paid subscription, the Standard plan rejects files over 5 MB, and two sync engines
> on one folder can lose edits. `.obsidian/workspace*.json` and each plugin's `data.json` (which
> holds your API key) are gitignored.

---

## 📂 3. Reproducing the results

Every number quoted in section 5 comes from these commands.

### 🔹 Run the tests

```bash
python -m pytest tests/ -q
```

### 🔹 The forward model and the jerk cost

```bash
python -m src.forward_model.forward_model    # the author's run: t, theta, V and a every 0.5 s
python -m src.forward_model.board_jerk       # T, D, C and J for the same run
```

```python
from src.forward_model import forward_model as fm, board_jerk as bj

t, V, a, complete = fm.simulate()            # 20 -> 0 deg over 3 s from 6 m/s, h = 0.001 s
bj.jerk_cost(t, a, complete)                 # J, dimensionless
fm.simulate(V0=6.5, k=1.1)                   # another start speed, friction scaled by 1.1
```

### 🔹 The friction force

```python
from src.friction import friction_force as ff
from src.friction.von_karman import von_karman as vk

A, L = ff.wetted_geometry()                  # the live solver's wetted area and length, pos_x 0.45
ff.F_f([2.0, 8.3], A, L)                     # N, Blasius laminar run
ff.F_f(8.3, A, L, laminar_avg_C_f=vk.avg_C_f)   # the Kármán laminar run instead
```

The Blasius and Kármán checks are notebooks, opened from their own folders:
`src/friction/blasius_shooting/rk4_blasius_checks_cc.ipynb`, `fd_vs_shooting_cc.ipynb`,
`shooting_for_blasius.ipynb` and `src/friction/von_karman/vonkarman.ipynb`.

### 🔹 The screens

```bash
python -m src.swd_model.identifiability_screen_live    # screen 2, about 7 minutes
python -m src.friction.rerun_live_screen_ff            # Gate B: screen 2 with F_f
```

### 🔹 The earlier surrogate

```python
from src.data import build_training_table, FEATURES
table = build_training_table()          # 389 rows, 13 boards, drift <= 20 deg
print(table[FEATURES].corr().round(3))
```

```python
from src.data import build_training_table
from src.evaluate import evaluate_all, fold_scores, summarise, pooled_score

table = build_training_table()
print(evaluate_all(table))                                   # every model x target
print(summarise(fold_scores(table, "drag_friction_n", "decision_tree")))
print(pooled_score(table, "drag_friction_n", "knn5"))        # the +0.52 reconciliation
```

```python
import pandas as pd
from src.predict import SurrogatePredictor
from src.data import build_training_table

model = SurrogatePredictor().fit(build_training_table())
model.predict(pd.DataFrame([{
    "volume_shape_l": 40.0, "length_over_width": 3.7,
    "thickness_over_length": 0.026, "drift_deg": 5.0, "roll_rad": 0.3,
}]))
```

### 🔹 Regenerate the HTML documentation

```bash
python -m pdoc --math --docformat numpy -o docs src
```

pdoc renders default arguments, which writes the absolute path of your checkout into the HTML. The
committed `docs/` has those paths cut back to repo-relative ones (`SWD/data/…`).

---

## 📂 4. Inputs and outputs

### 🔹 The forward model, `simulate()`

$m\,dV/dt = m g \sin\theta(t) - D(V, \theta)$, with $D = k F_f(V) + P(V, \theta) + R(V, \theta)$. P and R are
SWD's planing and rail drag at the slope θ, from the live solver at pos_y 0, pos_x 0.45, drift 0.
m = 802.21 N / 9.81 m/s².

| Input | Type | Unit | Range (default) | Domain |
|---|---|---|---|---|
| `V0` | float | m/s | 2–10 (6) | inside the force data |
| `k` | float | — | ≥ 0 (1) | multiplies F_f |
| `theta_start`, `theta_end` | float | degrees | −10 to 20 (20, 0) | inside the force data; positive is downhill |
| `T` | float | s | > 0 (3) | ramp and run length |
| `h` | float | s | > 0 (0.001) | T/h a whole number of steps |

| Output | Type | Unit | Meaning |
|---|---|---|---|
| `t` | float array | s | 0, h, …, up to T |
| `V` | float array | m/s | speed along the face at each node |
| `a` | float array | m/s² | dV/dt from the equation of motion at each node, not a finite difference |
| `complete` | bool | — | False if the run stopped because V left 2–10 m/s |

**Invalid input handling.** A non-finite, non-scalar or out-of-range input raises `ValueError`
naming the input, as does a step that does not divide T. Nothing is extrapolated: a run whose
speed leaves the force data stops at the last node inside it and returns `complete = False`.

### 🔹 The jerk cost, `jerk_cost(t, a, complete)`

$j = da/dt$, $J = \int_0^T C\,j^2/2\,dt$, $C = T^5/D^2$, with D the double integral of a (Charles et al.
2026, Eq 4–7, p.6). Along one axis, $D = |\int_0^T\!\int_0^t a\,ds\,dt|$, taken literally, with no
starting speed.

| | Type | Unit | Range | Domain |
|---|---|---|---|---|
| `t` (input) | float array | s | T = t[−1] − t[0] > 0 | strictly increasing, ≥ 3 samples, an even number of intervals |
| `a` (input) | float array | m/s² | finite | numeric, the same length as t |
| `complete` (input) | bool | — | must be True | the whole run, from `simulate()` |
| `J` (output) | float | dimensionless | ≥ 0 | |
| `D`, from `displacement` (output) | float | m | ≥ 0 | `jerk_cost` raises below 1e-5 m: C is undefined at 0 and meaningless near it |

Each of those conditions, broken, raises `ValueError` with its own message.

### 🔹 The friction force, `F_f(V, A, L)`

| | Type | Unit | Range | Domain |
|---|---|---|---|---|
| `V` (input) | float or array | m/s | > 0, finite | inside the converged speeds of A and L (2–10 m/s here) |
| `A`, `L` (input) | callables | m², m | from `wetted_geometry()` | not extrapolated |
| `rho`, `mu` (input) | float | kg/m³, Pa·s | SWD's 1025 and 0.00107 | finite, > 0 |
| `F_f` (output) | float or array | N | ≥ 0 | the same shape as V |

The transition point sits at Re = 5×10⁵, SWD's value, capped at the wetted length. The laminar run uses
the Blasius average coefficient from the shooting by default, and the turbulent run uses SWD's
0.031/Re_L^(1/7).

### 🔹 The earlier surrogate

All targets are board totals for one (board, drift, roll case), in newtons.

| Feature | Type | Unit | Range | Domain |
|---|---|---|---|---|
| `volume_shape_l` | float64 | litres | 24.0 – 130.7 | > 0 |
| `length_over_width` | float64 | — | 2.91 – 5.56 | ≥ 1 |
| `thickness_over_length` | float64 | — | 0.0105 – 0.0425 | > 0 |
| `drift_deg` | float64 | degrees | 0 – 20 | 0 – 90 available |
| `roll_rad` | float64 | radians | −0.200 – 1.368 | — |

Target ranges below are **corpus-wide, across all 11 drift angles**, not the envelope the
feature table describes. Inside the `drift ≤ 20°` envelope the extremes are smaller — lift
tops out at 841,823 N rather than 894,599 N — because the largest forces occur with the
board near broadside.

| Target | Unit | Range (all 11 angles) | Note |
|---|---|---|---|
| `drag_total_n` | N | 157 – 522,339 | SWD's own global field, **not** a sum of the others |
| `drag_friction_n` | N | 16.9 – 5,169 | the only target that generalises |
| `drag_planing_n` | N | 47 – 512,482 | |
| `drag_rail_n` | N | −5,541 – 15,951 | **negative is thrust**; zero on 113 rows means the rail is not engaged |
| `lift_total_n` | N | 982 – 894,599 | |

A NaN in a query is refused, not imputed — there is no defensible way to guess a board dimension. A
query outside the ranges above is predicted but flagged `in_envelope = False`, and by default warns;
`policy="refuse"` raises instead.

> ### 💬 Aside
> The envelope is a per-feature bounding box, so it will pass a combination that exists
> nowhere in the data — a 130 L hull with a shortboard's aspect ratio sits inside every
> individual margin. This is asserted as a known limitation in `tests/test_predict.py`
> rather than left to be discovered later. A convex hull would catch it; with 13 boards a
> convex hull would not be trustworthy either.

---

## 📂 5. Results, including the parts that did not work

Every grid and tolerance in the tests is the author's, chosen from tables of measured values before
any tolerance was written (`AI-USE.md` § 4).

### 🔹 The friction force

| Check | Result |
|---|---|
| RK4 (the author's `rk4_solve`) on y″ + 4y = 0 | fourth order: observed order p_obs → 4 |
| Blasius f″(0) by RK4 shooting, settled at η∞ = 20, against White's σ/√2 | within 8.9×10⁻¹² |
| A second-order central difference on the same grid | f″(0) within 1.7×10⁻⁵, against shooting's 1.5×10⁻⁸, in about a quarter of the time |
| Layer thicknesses against White and Majdalani, Table 4-4 | η₉₉ within 1.4×10⁻⁷; δ*/δ₉₉ to the table's 5 decimals; θ and H 2×10⁻⁴ out, the trapezoid's error |
| Skin friction C_f√Re_x from the shot | 4.3×10⁻⁹ from 2σ/√2 |
| Kármán integral with the Majdalani–Xuan quartic, Table 4-1 | all six values within half the last printed digit; C_f 0.517 % above Blasius; RK4 march p_obs = 4.069 |
| F_f against SWD's own friction, pos_x 0.45, 2–10 m/s | 0.985–0.989 of it |

### 🔹 The forward model

- The author's run, 20° → 0° over 3 s from 6 m/s, stays inside the force data: 6.00 → 7.31 m/s at
  1.5 s → **6.09056 m/s** at 3 s.
- RK4 against the author's closed form for m dV/dt = −cV²: p_obs = 3.990 on h = 3/96 to 3/384 s,
  with the error at h/4 inside the h/2 → h/4 change.
- Held at a constant 10°, a run from 6 m/s settles to within 0.034 m/s of the steady speed
  V* = 7.306 m/s after 30 s.
- SWD's own `drag_total_n`, which the model never uses as a force, crosses zero at 7.2926 m/s on
  the same slope (linear between 7 and 8 m/s). The model's V* is 0.0135 m/s away. This is the one
  check against an output the model does not consume.
- The author's first schedule failed. −10° → 20° over 10.055 s left the 2–10 m/s force data
  within 0.5–2.6 s for every starting speed from 4 to 10 m/s, so the ramp was changed to 20° → 0°
  over 3 s.

### 🔹 The jerk cost

On the author's run, D = 2.657 m, C = 34.42 s⁵/m² and **J = 64.58**.

| Check | Result |
|---|---|
| The author's linear case, a = 1 − 0.5t: D = 2.25 m, J = 18 | exact to round-off (7.1×10⁻¹⁵) |
| The author's sinusoid, a = sin(πt/3): J = π⁴/4 | p_obs = 2.0000 on h = 0.001, 0.0005, 0.00025 s |
| The author's run, subsampled to steps of 4h, 2h and h | p_obs = 2.0054 |
| J in other units (a in mm/s²; t in ms) | the same to 4.9×10⁻¹⁵, relative: J is dimensionless |

> ### 🧩 Point of note — D is taken literally
> Eq 7's double integral of acceleration leaves out the board's starting speed. On this run that
> makes D = 2.657 m. The distance actually travelled is 20.657 m, which would give J = 1.068, sixty
> times smaller. The author chose the literal form (`AI-USE.md` § 4).

### 🔹 The screens and Gate B

Two identifiability screens (2026-10-24) measured how well a fit recovers a friction multiplier k
from acceleration sampled at about 15 Hz. Gate B re-ran the second with F_f in place of SWD's
friction: every spread of the fitted k is 0.2–5.6 % wider. **Neither gate has a verdict yet;**
the author decides.

### 🔹 The earlier surrogate

A physics solver that takes **12 to 31 minutes** per board across 11 drift angles is too slow for a
shaper comparing hulls. The surrogate was trained on SWD's own output to predict the same forces in
microseconds. It was scored leave-one-board-out over 13 boards, in newtons. The SVR column is
**nested**: an inner grouped cross-validation on the training boards chose the hyperparameters, so the
held-out board never influences the model it scores.

| Target | SVR (nested) | folds < 0 | Decision tree | 5-NN |
|---|---:|---:|---:|---:|
| `drag_friction_n` | **+0.521** | **1/13** | +0.366 | +0.342 |
| `drag_rail_n` | −0.175 | 8/13 | +0.084 | +0.030 |
| `lift_total_n` | −0.302 | 9/13 | −0.265 | −0.170 |
| `drag_planing_n` | −0.540 | 10/13 | −0.506 | −0.387 |
| `drag_total_n` | −0.655 | 13/13 | −0.733 | −0.485 |

**Friction drag generalises to an unseen hull. Planing drag, total drag and lift do not.**
Geometry features improve every target, so the geometry axis is real; there is too
little of it at 13 hulls.

> ### 🧩 Point of note — the defaults were the story, and then they were not
> On scikit-learn's stock `gamma='scale'`, `C=100`, the SVR scored **−0.265** on
> friction: worse than the mean baseline, and beaten by a decision tree on its own
> defaults. That was a property of the defaults, not the method — 339 of 389 training
> rows became support vectors, which is memorisation. Nested tuning takes it to
> **+0.521**, and `gamma=0.1` was selected in **13 of 13** folds. Tuning did *not*
> rescue any other target, which is the useful part: hyperparameters cannot fix a
> shortage of hulls.
>
> Searching the grid against the held-out boards instead scores **+0.556**. That figure
> is 0.035 higher and is not reported as a result, because it was chosen by looking at
> the data it is scored on.

> ### 🧩 Point of note — the metric convention does more work than the model
> The same predictions, the same folds and the same model score **−0.485** per-fold in
> newtons, **+0.193** pooled in newtons, and **+0.284** pooled in signed-log space. Pooling
> moves between-board variance into the denominator, crediting the model for knowing that a
> 130 L paddleboard drags more than a 24 L shortboard — the one thing a board-grouped split
> exists to withhold. `src/evaluate.py` reports both so the flattering figure cannot be
> quoted alone.

### 🔹 What this validation cannot establish

- The forward model runs at one attitude (pos_y 0, pos_x 0.45, drift 0), along one axis down the
  face: no roll, yaw, added mass or unsteady force. Its forces exist only at 2–10 m/s and −10° to
  20°.
- SWD's rows do not decompose exactly. At that attitude, `drag_total_n` minus
  (friction + planing + rail − W sin θ) is within 4.3 N up to 15°. It reaches −10.2 N at 20° and
  −22.1 N at (2 m/s, −10°).
- The jerk cost is not compared with the paper; that comparison is future work. J here is for a
  3 s straight glide with no turns, not a surfed wave, and Radicality is not computed.
- The screens' set (b), which fits k and V0 together, is taken at 3 s to match the forward model's
  3 s run. At 3 s its fits depend on the optimiser's starting point and on the V0 ≤ 10 m/s bound:
  about 22 % of them stop on the bound, so its V0 spread is not what the data alone give. At
  10.055 s, mmc1's full wave, only 3 % do at the lower noise level, but the forward model cannot
  run that long at this attitude: held at 0° after its ramp, it leaves the force data at 5.07 s.
- The surrogate says nothing about other flow speeds. All 720 operating points were computed at
  20.000 m/s, and SWD's turbulent friction scales as `V^1.857`, not `V²`.
- Nothing about hulls outside 24–131 L, and little about combinations of shape not
  represented among 13 boards.
- Absolute dimensions carry a 1.56 % calibration bound. They are reconstructed through
  a single shape coefficient fitted on the two boards whose true length is independently
  known. The *ratios* are direct measurements and agree with SWD's own panel to 0.05 %.
- The drag components do not sum to the total in SWD's own data — 0 of 720 rows match,
  median residual +0.25 %. Any consistency audit must be scored against that residual, not
  against zero.
- `src/swd_model/trajectory.py`, the first trajectory model, sums its polar wrongly (`AI-USE.md`
  § 5 E133), so its forces, Board-Jerk and Radicality are inflated. It is superseded and not fixed.

---

## 📂 6. The data acquisition half

`SWD/` holds what was acquired from SWD:
- the extracted CSVs in `SWD/data/`;
- the live solver's tables;
- the documentation of how they were made, in `SWD/docs/` and `SWD/README.md`.

Nothing in `src/` writes into the extracted data.

The PowerShell that did the acquisition has been kept out of the public repository since
2026-10-28. That is the binary-report extractor, the `SWD/tools/phase2/` scripts that drove the live
application through Win32 messages and UI Automation to acquire new scans, and their Pester tests.
They need **Windows PowerShell 5.1** (`powershell.exe`, not `pwsh` 7) and a licensed SWD installation;
nothing in `src/` needs either. The extractor was read-only against the
installation: it never launched SWD, never wrote into the program directory, and never modified a
library file in place. Its provenance gate would not deserialise a file whose SHA-256 was absent from
a trust manifest, because `BinaryFormatter.Deserialize` on an untrusted stream is arbitrary code
execution.

The Python helpers in `SWD/tools/` (the column translation, the data dictionary and the computed
views) stay in the repository.

---

## 📂 7. Licence and attribution

See `LICENSE`. The paper this project's performance metrics follow is Charles et al. (2026),
*Results in Engineering* 29:108868, DOI 10.1016/j.rineng.2025.108868. Its supplementary
data is redistributed here under CC BY 4.0 with attribution recorded in
`SWD/data/paper-supplementary/SOURCE.md`; the paper itself is cited, not redistributed.

The boundary-layer reference values come from White and Majdalani, *Viscous Fluid Flow* (2022),
chapter 4: Table 4-1 (p.158), Table 4-4, and Eq. 4-64 (p.170).

SWD itself is commercial software and none of it is redistributed here — only measurements
taken from a licensed installation.

---

## 📂 8. How AI was used, and how it was checked

The unit's project brief permits AI throughout the project, requires that all material use be
disclosed, and lists eight things the reflection must explain (Project Brief, p. 6). It also says,
in bold, that AI cannot be used to answer questions in the interview — so everything here has to
be explicable by the author without it. The full record is [`AI-USE.md`](AI-USE.md); this section
says where each answer is and how the checking worked.

| The brief asks for | Where it is answered |
|---|---|
| which AI tools were used | `AI-USE.md` § 1 |
| what they were used for | `AI-USE.md` § 2 |
| the approximate level of AI contribution | `AI-USE.md` § 3 |
| why AI was used for those tasks | `AI-USE.md` §§ 2–3 |
| how AI-generated material was checked | below, and `AI-USE.md` § 5 |
| which important decisions remained the student's responsibility | `AI-USE.md` § 4 |
| any errors, limitations or unhelpful suggestions produced by AI | `AI-USE.md` § 5 |
| how AI use affected the student's understanding or workflow | `AI-USE.md` § 4, and below |

### 🔹 The tools

| Tool | Version | Model | Used for |
|---|---|---|---|
| Claude Code (Anthropic) | 2.1.246–2.1.311 | `claude-opus-5`; `claude-opus-5-5` from 23 Sep 2026 | writing and editing code and documents under direction — 42 sessions, 435 prompts, 26 Aug – 27 Oct 2026 |
| SQA-loop agents, run inside Claude Code | as installed Aug 2026; rebuilt 27 Sep 2026 | `claude-opus-5`, then `claude-opus-5-5` | reviewing and fixing that code — 15 review dispatches and 6 fix rounds in Aug–Sep 2026; read-only `sqa-numerical` and `sqa-functional` reviews in Oct 2026 |
| humanizer plugin | 2.11.2 | the session's model | four prose passes over this README, the latest on 28 Oct 2026, each followed by a fact diff |
| graphify | 0.9.52 | none for code | a navigation graph of the repo; gitignored, not a deliverable; retired 14 Sep 2026 |
| Google Antigravity CLI (agy) | 2026-09 onwards | Gemini (3.8 Flash, 3.1 Pro, 4 Argon, as selected) | auditing and fixing the SWD extraction code (24–25 Sep 2026); since 27 Sep, the first stage of the SQA pass; from Oct 2026, review-only checks of the friction, forward-model and jerk-cost code |
| Devin CLI (Cognition) | 3000.11.3 | `swe-1-7` | drafting the second-source auditor config (24 Sep 2026); since 27 Sep, the second stage of the SQA pass; from Oct 2026, the second review-only check |

`pdoc`, `pytest`, `Pester` and `PSScriptAnalyzer` are not AI and are listed only so the question
does not arise.

### 🔹 Verification by agentic review — the SQA loop

Code that an AI wrote was reviewed by AI agents that could not edit it, fixed by an agent that
could not grade its own work, and re-reviewed by a fresh instance every round. The tooling is
[bennmoors/SQA-loop](https://github.com/bennmoors/SQA-loop); the process, in brief:

1. **`sqa-lead`** scopes the target and dispatches specialists in parallel by domain —
   `sqa-functional` (correctness, ISTQB test design), `sqa-security` (OWASP/ASVS, secrets, data
   leaks), `sqa-efficiency` (profiling and energy), and `sqa-embedded` / `sqa-numerical` when the
   target warrants them. Every finding carries an evidence label (`[Proven]`, `[High]`,
   `[Needs-info]`), and only the first two can raise the severity count.
2. The merged report ends in one parseable line, **`VERDICT: Critical=N | Warning=N |
   Suggestion=N`**, which is the gate: loop while Critical or Warning is above zero.
3. **`code-reviewer`** — the only agent allowed to edit — takes the findings verbatim and either
   fixes each one or rebuts it with evidence. It never drops a finding silently.
4. A **fresh `sqa-lead`** verifies. The instance that reviewed is never the one that certifies the
   fix. The table below is the reason: the fixer's own verdict and the verifier's disagreed in
   every round where both exist.
5. Two `PreToolUse` guards enforce this at the harness, so it does not depend on an agent obeying
   its prompt. An SQA agent that tries to write a file is refused, and so is the fixer when it
   reaches for the tests or the scoring script.

What that produced here, copied from the repo's own worklists:

| Target | Intake | After fix (fixer's own verdict) | Fresh verifier | Source |
|---|---|---|---|---|
| Phase 1 extractor (`swd_extract.ps1`), three rounds | `C=3 W=5 S=19` | `C=1 W=0 S=5` (the Critical is a security patch parked for sign-off) | **`C=1 W=3 S=5`** — its Critical was a hole in a guard the fix rounds themselves had added | `SWD/TODO.md`, "SQA round 1" to "Final verification" |
| Phase 2 UI automation (`swd_msg.ps1`, `swd_diagnose.ps1`), round 1 | `C=6 W=11 S=14` | `C=0 W=0 S=2` | **`C=1 W=4 S=8`** | `SWD/TODO.md`, "QA loop CLOSED — 2026-08-28" |
| same, round 2 | — | `C=0 W=0 S=4` | **`C=1 W=2 S=5`** | same |
| same, round 3 (closed at the round cap) | — | `C=0 W=0 S=3` | **`C=0 W=7 S=11`** | same |
| Extraction and census scripts (`extract_board.ps1`, `census_board.ps1`) | `C=1 W=9 S=24` | `C=0 W=1 S=1` | **`C=1 W=14 S=20`**, then a third fixer round reported `(CLEAN)` with 67/67 Pester — closed at the cap on the fixer's word, not a verifier's | `SWD/data/default_shortboard/PROGRESS.md`, "SQA loop outcome" |
| UIA board switching (`swd_board.ps1`, `swd_geometry.ps1`), round 1 | `C=2 W=16 S=17` | `C=0 W=0 S=2` (2 deferred with reasons, 1 rebutted) | **`C=2 W=6 S=9`** — "fixer's CLEAN did not hold" | `TODO.md`, Tier 2b |
| same, round 3 | — | `C=0 W=0 S=2`, and the fixer found a third Critical itself that two review rounds had missed | **`C=0 W=2 S=13`**, cap reached, not clean; the two Warnings were then fixed without an independent pass | `TODO.md`, Tier 2b |

The PowerShell scripts in this table, and the root `TODO.md`, have been kept out of the public
repository since 28 Oct 2026.

> ### 🧩 Point of note — the fixer reports itself clean, and the verifier disagrees
> In each of the three Phase 2 rounds the fixing agent's own verdict was `Critical=0 | Warning=0`,
> and each time the independent verifier found more. The extraction loop went the same way: the
> fixer reported one Warning, the verifier fourteen. The UIA loop too: a fixer's clean verdict
> came back as two Criticals. In round 1 of the Phase 2 loop the fixes themselves introduced one
> new Critical and three regressions (`SWD/tools/phase2/SQA-FINDINGS.md`), and the Phase 1
> verifier's one Critical was a hole in a guard the earlier fix rounds had added. `SWD/TODO.md`
> puts it in one line: "Twice a fixer reported clean and a fresh verifier immediately found a
> Critical. That is why the verifier is never the author." It is also why the loop gates on the
> verifier's line and ignores the fixer's.

> ### 🧩 Point of note — the process changed on 27 September 2026
> Everything above describes the multi-round loop. From 2026-09-27, `/sqa-loop` is **one unattended
> pass**. A quota check first leaves out any CLI that is low on usage (no other CLI is swapped in).
> Then agy tests and fixes, and Devin tests and fixes the tree agy left. Both run headless through a
> wrapper that reverts any write outside their allowed paths. Last comes one Claude `sqa-lead` with
> its specialists and one `code-reviewer`, and that verdict is final. There is **no fresh-verifier
> round any more**, so the fixer's edits in that last step are not re-checked, which is the
> weakness the table above documents. No pass of this kind had been run on this repository as of
> 2026-09-29. From October 2026, agy and Devin ran review-only rounds through the same wrapper on
> the friction, forward-model and jerk-cost code, with Claude Code applying the fixes. Details, the
> reasons, and three faults found in trial runs: `AI-USE.md` § 2 (2026-09-26/27 and 2026-09-27) and
> § 5 E78–E80.

### 🔹 Errors the AI made

The brief's Excellent band asks for "identification of errors", and its Poor band names
"unrecognised errors". The acquisition half already carries its own acknowledgement,
`SWD/README.md` § AI Acknowledgment, which names five. `AI-USE.md` § 5 indexes every correction
recorded anywhere in the repository — E1 to E160 as of 27 Oct 2026, starting from 62 harvested from
the project's documents. Four that changed the work:

- An AI-written note computed `rho = 1023.154` with a "0.015% density residual" and inferred a
  second flow speed of 20.039 m/s. Both were artefacts of dividing a bimodal mixture by one assumed
  density; there was one speed at two water temperatures. Re-measuring the ratio on a single board
  caught it (`.claude/rules/swd-technical-facts.md`, moved there from `CLAUDE.md` § 5).
- A "2.7× faster at low speed" cost re-base compared two boards that had both been scanned at
  ~20 m/s, so it measured hull geometry, not speed. It was withdrawn after the live run
  (`SWD/TODO.md`, "Cost model").
- A stage plan was written against a `NumericUpDownScanSpeed*kmh` control and a km/h conversion.
  The live application has a `flow ms` box, in m/s, and the planned value would have requested
  130 km/h. Reading the control map before scanning caught it.
- `CLAUDE.md` § 2 carried a seven-row weighted marking table and a "20% withheld split with RMSE"
  requirement, both cited to the brief. The brief's rubric has six unweighted criteria and lists
  withheld data as one of ten validation options. Reading the PDF text directly while writing this
  section caught it.

### 🔹 The prompt log

`AI-USE.md` § 6 is every prompt given to Claude Code, agy and Devin for this repository — 458 across
58 sessions as of 27 Oct 2026 (Claude Code 435, agy 21, Devin 2), verbatim and timestamped. It is
recovered from the session transcripts the CLIs keep outside the repo and regenerated by
`python tools/extract_prompts.py`, which a hook has run at the end of every Claude Code session since
29 Sep 2026. The home directory is redacted; anything that looks like a licence or registry
reference is flagged for a human to check. The brief does not ask for this; it is included because
"complete disclosure" is easier to demonstrate than to assert.

---

<!-- REVIEW: drafted from AI-USE.md by Claude Code. Read every sentence, change what is not
     true in your own words, and delete this comment. This section is exempt from style passes. -->

## 🤖 AI Acknowledgment

> Parts of this repository were developed with the assistance of **Claude Code** (Anthropic; CLI
> versions 2.1.246–2.1.311, models `claude-opus-5` and `claude-opus-5-5`, accessed 26 August –
> 28 October 2026), which wrote and edited code and documentation under my direction across 42
> sessions and 435 prompts (to 27 October), and ran the **SQA-loop** review agents over its own
> output. **Google Antigravity (agy)** and **Devin CLI** audited the code, and from October reviewed
> it without editing it. The **humanizer** plugin (2.11.2) was used for four prose passes over this
> README. **graphify** (0.9.52) built a navigation graph that is not part of the submission; it was
> retired on 14 September 2026.
>
> AI was used for the SWD extraction and UI-automation scripts, the surrogate pipeline in `src/`,
> the friction-function, forward-model and jerk-cost code in `src/` (implementing my own
> derivations), the test suites, and the drafting of the documentation. The complete record — what
> was asked, what came back, what I changed, and what it got wrong — is `AI-USE.md`.
>
> All content has been reviewed, verified and adapted by the author. Verification was by
> measurement against SWD's own output, decompilation of the solver where its formulas were in
> question, live runs against the application, the pytest and Pester suites, known-answer and
> convergence tests against my derivations and textbook values, and independent agentic review
> (with a fresh verifier every round until 27 September 2026). The errors that process caught are
> listed in `AI-USE.md` § 5 rather than hidden. I am responsible for every claim, result, reference
> and engineering decision in this repository.
