# 📘 Virtual Surfer — a board-geometry surrogate for SWD

MMA3001 Numerical Methods and Machine Learning — individual project.

A physics-based hydrodynamic solver (ShaperWaveDynamics, "SWD") takes **12 to 31 minutes**
to evaluate one surfboard across 11 drift angles. A shaper comparing hulls cannot wait that
long per design. This repository trains a machine-learning surrogate on SWD's own output so
the same forces can be predicted in microseconds, and reports honestly on where that
surrogate works and where it does not.

---

## 📂 1. What is in here

    HYDRODYNAMICS-FIN/
    ├── src/                     the surrogate (this project's own work)
    │   ├── geometry.py          recover board dimensions from SWD's binary fields
    │   ├── data.py              build the training table; feature/target contract
    │   ├── splits.py            board- and family-grouped splitting
    │   ├── models.py            SVR, decision tree, 5-NN, mean floor
    │   ├── physics_baseline.py  SWD's own friction law, as a comparator
    │   ├── evaluate.py          leave-one-board-out, per-fold and pooled
    │   └── predict.py           query API with envelope checking
    ├── tests/                   85 pytest tests
    ├── docs/                    pdoc HTML, generated
    ├── SWD/                     DATA ACQUISITION ONLY — see section 6
    └── TODO.md                  live worklist

**`src/` and `SWD/` are separate on purpose.** `SWD/` extracts data out of a licensed
third-party application and is frozen; `src/` is the modelling. Nothing in `src/` writes
into `SWD/data/`.

---

## 📂 2. Setup

Python **3.12 or newer** (developed on 3.14.6). No virtual environment is assumed.

```bash
pip install -r requirements.txt
```

| Package | Why |
|---|---|
| numpy, pandas | array and table handling |
| scipy | integration and root-finding in the trajectory model |
| scikit-learn ≥ 1.9 | SVR, decision tree, k-NN, pipelines, metrics |
| pytest | the test suite |
| pdoc | HTML API documentation |

> ### 🧩 Point of note
> scikit-learn needs a wheel built for your interpreter. On Python 3.14 that means
> **scikit-learn 1.9.0 or later** — earlier releases have no `cp314` wheel and `pip` will
> fall back to a source build that requires a C++ toolchain.

The data acquisition half additionally needs **Windows PowerShell 5.1** (`powershell.exe`,
not `pwsh` 7) and a licensed SWD installation. Neither is needed to run the model.

---

## 📂 3. Reproducing the results

Every number quoted in section 5 comes from these commands.

### 🔹 Run the tests

```bash
python -m pytest tests/ -q
```

### 🔹 Build the training table and inspect the features

```python
from src.data import build_training_table, FEATURES
table = build_training_table()          # 389 rows, 13 boards, drift <= 20 deg
print(table[FEATURES].corr().round(3))
```

### 🔹 Reproduce the evaluation

```python
from src.data import build_training_table
from src.evaluate import evaluate_all, fold_scores, summarise, pooled_score

table = build_training_table()
print(evaluate_all(table))                                   # every model x target
print(summarise(fold_scores(table, "drag_friction_n", "decision_tree")))
print(pooled_score(table, "drag_friction_n", "knn5"))        # the +0.52 reconciliation
```

### 🔹 Query the surrogate

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
python -m pdoc --output-directory docs --docformat numpy src
```

---

## 📂 4. Inputs and outputs

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

**Invalid input handling.** A NaN in a query is refused, not imputed — there is no
defensible way to guess a board dimension. A query outside the ranges above is predicted
but flagged `in_envelope = False`, and by default warns; `policy="refuse"` raises instead.

> ### 💬 Aside
> The envelope is a per-feature bounding box, so it will pass a combination that exists
> nowhere in the data — a 130 L hull with a shortboard's aspect ratio sits inside every
> individual margin. This is asserted as a known limitation in `tests/test_predict.py`
> rather than left to be discovered later. A convex hull would catch it; with 13 boards a
> convex hull would not be trustworthy either.

---

## 📂 5. Results, including the parts that did not work

Leave-one-board-out over 13 boards, scored in newtons. The SVR column is **nested**:
hyperparameters are chosen by an inner grouped CV on the training boards only, so the
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

- Nothing about speed. All 720 operating points were computed at 20.000 m/s. Speed is
  not a feature because it has no variance, and SWD's turbulent friction branch scales as
  `V^1.857`, not `V²`, so results cannot simply be rescaled.
- Nothing about hulls outside 24–131 L, and little about combinations of shape not
  represented among 13 boards.
- Absolute dimensions carry a 1.56 % calibration bound. They are reconstructed through
  a single shape coefficient fitted on the two boards whose true length is independently
  known. The *ratios* are direct measurements and agree with SWD's own panel to 0.05 %.
- The drag components do not sum to the total in SWD's own data — 0 of 720 rows match,
  median residual +0.25 %. Any consistency audit must be scored against that residual, not
  against zero.

---

## 📂 6. The data acquisition half

`SWD/` reads SWD's binary report files and writes CSVs. It is **frozen and extract-only**:
`extract_board.ps1` and `census_board.ps1` carry a clean SQA verdict and 67 Pester tests,
and nothing this project computes is written back into `SWD/data/`.

It is read-only against the installation: it never launches SWD, never writes into the
program directory, and never modifies a library file in place. A provenance gate will not
deserialise a file whose SHA-256 is absent from a trust manifest, because
`BinaryFormatter.Deserialize` on an untrusted stream is arbitrary code execution.

`SWD/tools/phase2/` drives the live application through Win32 messages and UI Automation to
acquire new scans. Those scripts are gated behind their own SQA pass before any live run.

---

## 📂 7. Licence and attribution

See `LICENSE`. The paper this project's performance metrics follow is Charles et al. (2026),
*Results in Engineering* 29:108868, DOI 10.1016/j.rineng.2025.108868, and its supplementary
data is redistributed here under CC BY 4.0 with attribution recorded in
`SWD/data/paper-supplementary/SOURCE.md`.

SWD itself is commercial software and none of it is redistributed here — only measurements
taken from a licensed installation.
