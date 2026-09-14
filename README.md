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
    ├── tests/                   92 pytest tests
    ├── docs/                    pdoc HTML, generated
    ├── SWD/                     DATA ACQUISITION ONLY — see section 6
    ├── AI-USE.md                the AI-use record — see section 8
    ├── tools/extract_prompts.py regenerates the prompt appendix in AI-USE.md
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

### 🔹 Optional: Obsidian and Claude Code

The repository root is also an Obsidian vault. Project notes link to each other with relative
Markdown links, the worklist is a Base (`SWD/docs/worklist/worklist.base`), and Claude Code's
memory for this project lives in `memory/`. None of this is needed to run the model.

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
| Claude Code (Anthropic) | 2.1.246–2.1.258 | `claude-opus-5` | writing and editing code and documents under direction — 6 sessions, 70 prompts, 26 Aug – 2 Sep 2026 |
| SQA-loop agents, run inside Claude Code | as installed Aug 2026 | `claude-opus-5` | reviewing and fixing that code — 15 review dispatches, 6 fix rounds |
| humanizer plugin | 2.11.2 | `claude-opus-5` | three prose passes over this README, each followed by a fact diff |
| graphify | 0.9.52 | none for code | a navigation graph of the repo; gitignored, not a deliverable |

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

### 🔹 Errors the AI made

The brief's Excellent band asks for "identification of errors", and its Poor band names
"unrecognised errors". The acquisition half already carries its own acknowledgement,
`SWD/README.md` § AI Acknowledgment, which names five. `AI-USE.md` § 5 indexes every correction
recorded anywhere in the repository — 62 harvested from the project's documents, plus the ones
made while writing this section. Four that changed the work:

- An AI-written note computed `rho = 1023.154` with a "0.015% density residual" and inferred a
  second flow speed of 20.039 m/s. Both were artefacts of dividing a bimodal mixture by one assumed
  density; there was one speed at two water temperatures. Re-measuring the ratio on a single board
  caught it (`CLAUDE.md` § 5).
- A "2.7× faster at low speed" cost re-base compared two boards that had both been scanned at
  ~20 m/s, so it measured hull geometry, not speed. It was withdrawn after the live run
  (`CLAUDE.md` § 9).
- A stage plan was written against a `NumericUpDownScanSpeed*kmh` control and a km/h conversion.
  The live application has a `flow ms` box, in m/s, and the planned value would have requested
  130 km/h. Reading the control map before scanning caught it.
- `CLAUDE.md` § 2 carried a seven-row weighted marking table and a "20% withheld split with RMSE"
  requirement, both cited to the brief. The brief's rubric has six unweighted criteria and lists
  withheld data as one of ten validation options. Reading the PDF text directly while writing this
  section caught it.

### 🔹 The prompt log

`AI-USE.md` § 6 is every prompt given to Claude Code for this repository — 70 of them, verbatim,
timestamped — recovered from the session transcripts Claude Code keeps outside the repo and
regenerated by `python tools/extract_prompts.py`. The home directory is redacted; anything that
looks like a licence or registry reference is flagged for a human to check. The brief does not
ask for this; it is included because "complete disclosure" is easier to demonstrate than to
assert.

---

<!-- REVIEW: drafted from AI-USE.md by Claude Code. Read every sentence, change what is not
     true in your own words, and delete this comment. This section is exempt from style passes. -->

## 🤖 AI Acknowledgment

> Parts of this repository were developed with the assistance of **Claude Code** (Anthropic; CLI
> versions 2.1.246–2.1.258, model `claude-opus-5`, accessed 26 August – 2 September 2026), which
> wrote and edited code and documentation under my direction across six sessions and 70 prompts,
> and ran the **SQA-loop** review agents over its own output. The **humanizer** plugin (2.11.2) was
> used for three prose passes over this README. **graphify** (0.9.52) built a navigation graph that
> is not part of the submission.
>
> AI was used for the SWD extraction and UI-automation scripts, the surrogate pipeline in `src/`,
> the test suites, and the drafting of the documentation. The complete record — what was asked,
> what came back, what I changed, and what it got wrong — is `AI-USE.md`.
>
> All content has been reviewed, verified and adapted by the author. Verification was by
> measurement against SWD's own output, decompilation of the solver where its formulas were in
> question, live runs against the application, the pytest and Pester suites, and independent
> agentic review with a fresh verifier every round. The errors that process caught are listed in
> `AI-USE.md` § 5 rather than hidden. I am responsible for every claim, result, reference and
> engineering decision in this repository.
