# 📘 AI use record — MMA3001 individual project

This file is the single record of how AI was used in this repository. It exists because the
project brief requires "complete disclosure" of AI use (Project Brief, p. 15) and lists eight
things the reflection must explain (p. 6). Each of those eight is answered by a section here:

| Brief, p. 6 — the reflection must explain | Answered in |
|---|---|
| which AI tools were used | § 1 |
| what they were used for | § 2 |
| the approximate level of AI contribution | § 3 |
| why AI was used for those tasks | § 2, § 3 |
| how AI-generated material was checked | § 2, § 5, README § 8 |
| which important decisions remained the student's responsibility | § 4 |
| any errors, limitations or unhelpful suggestions produced by AI | § 5 |
| how AI use affected the student's understanding or workflow | § 4, README § 8 |

The rules that govern this file are in `CLAUDE.md` § 3 (R1–R12). It is **append-only**: a wrong
entry is corrected by a later entry, never edited away. Sections marked `[REVIEW]` were drafted
from the evidence by Claude Code and must be read, corrected and owned by the author before
submission — they are statements the author is graded on.

The data-acquisition half has an acknowledgement of its own, written 2026-08-27:
`SWD/README.md` § AI Acknowledgment. This file does not replace it; it covers the whole
repository and indexes what that section records.

---

## 📂 1. Tools

| Tool | Version(s) | Model | Access dates | What it did |
|---|---|---|---|---|
| **Claude Code** (Anthropic CLI agent) | 2.1.246 – 2.1.258 | `claude-opus-5` throughout; `claude-fable-5-1` on part of the 2026-09-02 session; one subagent turn on `claude-opus-4-8` | 2026-08-26 → 2026-09-02 | Wrote and edited code and documents under direction; 6 interactive sessions, 70 prompts (§ 6); 897 shell calls, 196 PowerShell calls, 108 file writes, 63 edits, 53 web fetches, 24 web searches. |
| **SQA-loop** — a seven-agent review suite run inside Claude Code ([bennmoors/SQA-loop](https://github.com/bennmoors/SQA-loop)) | as installed 2026-08 | `claude-opus-5` | 2026-08-26 → 2026-09-02 | 15 `sqa-lead` review dispatches (each fanning out to `sqa-functional`, `sqa-security`, `sqa-efficiency` by domain) and 6 `code-reviewer` fix rounds; 77 subagent transcripts in total. Review-only agents never edit; the fixer never grades its own work. See README § 8. |
| **Explore / general-purpose subagents** (Claude Code built-ins) | — | `claude-opus-5` | 2026-08-26 → 2026-09-02 | 14 read-only codebase/document searches and 2 research tasks (e.g. reading the project brief PDF, inventorying generated files). |
| **humanizer** (Claude Code plugin) | 2.11.2 | `claude-opus-5` | 2026-09-01 → 2026-09-02 | 3 prose passes over human-read documents (README), each followed by a before/after fact diff. Never applied to this file or to the acknowledgement section. |
| **graphify** (`graphifyy`) | 0.9.52 | none for code (tree-sitter AST); configured `claude-cli` backend for docs | 2026-08-30 → 2026-09-02 | Built a queryable knowledge graph of the repo for navigation. Output is gitignored; nothing it produced is a deliverable. |
| **Claude Code** (Anthropic CLI agent) — later entry | 2.1.270 | `claude-opus-5` | 2026-09-14 | Researched the Obsidian CLI, Obsidian MCP servers and Claude Code memory settings (6 research subagents against primary sources, plus a read of the installed binary); retired graphify; built the Obsidian knowledge-base layout, the `obsidian-memory` skill and the README setup block. |
| **graphify** (`graphifyy`) — later entry | 0.9.52 | — | retired 2026-09-14 | Removed: git hooks, merge driver, PreToolUse hooks, `CLAUDE.md` section and `graphify-out/` deleted; skill archived; tool uninstalled. See § 5 E75. |

Not AI, listed to pre-empt the question: `pdoc` 16 (deterministic HTML from docstrings), `pytest`,
`PSScriptAnalyzer`, `Pester`, `pypdf`.

**Known biases and limitations of the tools used, as observed in this project** `[REVIEW]`:
a large language model will state a specific number or control name with full confidence when the
source contains none (§ 5: the rubric weights, the "20% split", the `kmh` control); it reaches for
the textbook-familiar formula before the one actually in the software (§ 5: ITTC-57 assumed until
the friction law was decompiled); and it reads its own earlier output as a source unless told not
to (§ 5: the "0.015% density residual" survived one correction cycle because the correction cited
the note that was wrong). Every one of these was caught by measurement, decompilation or a live
run, not by asking the model again.

---

## 📂 2. Task log `[REVIEW]`

What AI produced, why it was used for that task, and how the output was checked. Seeded from the
repository's own worklists (`TODO.md`, `SWD/TODO.md`, `SWD/data/default_shortboard/PROGRESS.md`)
and the transcripts in § 6; the "why" column is the author's to confirm. From here on, per
`CLAUDE.md` R2, an entry is added whenever AI output ships or changes a decision.

| Date | What AI produced | Why AI was used | How it was checked | Record |
|---|---|---|---|---|
| 2026-08-26 | `swd_extract.ps1`, 1,195 lines: SWD `.fyn*` binary → CSV, by reflecting over the undocumented assembly | The format is undocumented and reverse-engineering it by hand would have taken longer than the project allows | 133 Pester tests + a mutation harness; three SQA rounds with an independent verifier; full extraction run three times and compared byte-for-byte | `SWD/TODO.md` § Phase 1; `SWD/README.md` § AI Acknowledgment |
| 2026-08-26/27 | The four corpus tables (`boards.csv`, `operating_points.csv`, `elements.csv`, `fin_polars.csv`) | — (output of the script above; no value was generated by AI) | Physical cross-checks: speed recovered from `ṁ = ρAV`; the half-discarded fin database found by SQA (§ 5 E23) | `SWD/TODO.md` |
| 2026-08-27 | `BinaryFormatter` provenance gate (SHA-256 trust manifest) | An SQA security finding showed "these are your own files" was false (§ 5 E25) | Applied and verified by running; containment tested behaviourally against sandbox stand-ins | `SWD/docs/provenance-gate.md` |
| 2026-08-27 | `SWD/README.md`, `provenance-gate.md`, `phase2-hydroscan.md`, `coverage.md`, `CLAUDE.md` | Drafting speed; every headline number was re-derived by a different party than the one that produced it | Numbers re-derived; the UIPI diagnosis in `phase2-hydroscan.md` § 5 was later refuted by measurement and rewritten (§ 5 E16–E17) | `SWD/TODO.md` |
| 2026-08-27 | `swd_msg.ps1` + `swd_diagnose.ps1`: Win32 message layer and a read-only diagnostic for driving SWD | SWD has no API; the only route to new scans is its GUI | Full SQA fan-out (`C=6 W=11 S=14`): five of six Criticals were instruments reporting states they never measured (§ 5 E33); three-round loop closed at cap `C=0 W=7 S=11` | `SWD/tools/phase2/SQA-FINDINGS.md`, `BUILD-NOTES.md` |
| 2026-08-28 | Modal-dialog layer + 11 tests; first driven hydroscan (11 angles, 05:11→05:41) | The scan flow raises dialogs the driver must answer safely | Pester 191/191; the safety gate was found to match a property that did not exist (§ 5 E54) before anything touched SWD; scan timed end to end (§ 5 E12) | `SWD/TODO.md` |
| 2026-08-29 | Four stage plans (`SWD/docs/plans/`) | To split multi-day work into standalone stages | Executed 2026-08-31; the km/h and `flow ms` premises both refuted live (§ 5 E7–E10) | `SWD/docs/plans/*.md` |
| 2026-08-31 | Verification scan under tool control; `LIVE-RUN-FINDINGS.md`, `SCAN-FLOW.md`; corpus 667 → 720 points | The stage plan's gate required a live measurement before any batch automation | The experiment failed its own gate and said so; the "2.7× faster" inference withdrawn the same evening (§ 5 E11) | `SWD/tools/phase2/LIVE-RUN-FINDINGS.md` |
| 2026-08-31 | WP1: paper supplementary data saved with SHA-256 and `SOURCE.md`; WP2: `performance-metrics.md`, all 17 equations | Transcription and audit of a long paper | 71/72 self-consistency audit; four defects in the plan's description of the archives found by reading inside them (§ 5 E41–E44); Table 9 reconstructed rather than parsed (§ 5 E45) | `SWD/data/paper-supplementary/SOURCE.md`, `SWD/docs/performance-metrics.md` |
| 2026-08-31 | `what-swd-can-yield.md`, `project-io-spec.md`; bounded decompile of the density table and friction law, reimplemented in Python | To establish what SWD can and cannot provide before building a model on it | Friction law compared against SWD's own `_Fx_friction_n` (§ 5 E4, E5); density table explains the two corpus values exactly (§ 5 E2, E3) | `SWD/docs/`, `PROGRESS.md` |
| 2026-09-01 | `census_board.ps1`, `extract_board.ps1`, `DATA-DICTIONARY.md`, `make_computed_view.py`, `SWD/model/trajectory.py`; corpus regenerated at ρ-corrected values | The per-board extraction and the computed/extracted split were required by the data-integrity rules | SQA loop `C=1 W=9 S=24` → fresh verifier `C=1 W=14 S=20` → fixer CLEAN, 67/67 Pester; Ra bug (§ 5 E38) self-caught | `PROGRESS.md` |
| 2026-09-01 | ML pipeline `src/` (7 modules), 85 pytest tests, `pdoc` HTML, `README.md`, `LICENSE`, `profiling.py` | Implementation speed; the author chose the targets, the split rule and the reporting policy | Leave-one-board-out with nested CV; both metric conventions reported (§ 5 E47); drag non-additivity measured (§ 5 E48); humanizer pass on README with fact diff | `TODO.md` Tier 1 |
| 2026-09-01/02 | `swd_board.ps1` + `swd_geometry.ps1` (UIA), Pester suite, mutation sweep | Board switching is a prerequisite for any headless batch | SQA rounds 1–3 with fresh verifiers (`C=2 W=16 S=17` → `C=2 W=6 S=9` → `C=0 W=2 S=13`, cap); mutation sweep exposed three tests passing for the wrong reason (§ 5 E51); a live mutant left in the source for 25 min (§ 5 E52) | `TODO.md` Tier 2b |
| 2026-09-02 | `.gitignore` rules for computed views; `tools/extract_prompts.py` + test; this file; `CLAUDE.md` § 2–3 rewrite; README § 8 | The brief's AI-use requirements had to be read from the source and turned into rules; prompts were recoverable only while transcripts survive | Brief verified against the PDF text; rubric weights and "20% split" found to be fabrications (§ 5 E63–E64); 7 new tests, 92/92 passing | this file, `CLAUDE.md` § 3 |
| 2026-09-14 | Obsidian integration: `SWD/docs/worklist/` (7 notes + `worklist.base`) replacing the `CLAUDE.md` § 9 table; `CLAUDE.md` §§ 3.1–3.2 and 5 moved verbatim to path-scoped `.claude/rules/`; 166 backticked `.md` references turned into relative links; `memory/` moved into the repo; `.claude/skills/obsidian-memory/`; `.mcp.json` + permission denies; README § 2 Obsidian setup; graphify removed | Token cost: graphify's hooks had injected ~350 stale-graph notices across 8 sessions, and `CLAUDE.md` loaded 30 KB every session; and to make the repo usable by a collaborator | Rule-inventory diff: all 340 non-blank `CLAUDE.md` lines found verbatim in the new files except 19 removed graphify lines and 5 deliberately edited lines; `obsidian base:query` returned 7 rows matching the old table; `obsidian unresolved` empty; path-scoped rules observed loading on reads under `SWD/` and of `README.md`; skill frontmatter parsed with `yaml.safe_load`; README one-liner run in pwsh 7 and PowerShell 5.1 (no BOM); humanizer pass on the new README block made no change | Prompts 2026-09-14 (§ 6); plan `~/.claude/plans/i-have-just-downloaded-zesty-trinket.md` |
| 2026-09-14 | `tools/extract_prompts.py`: also read `queued_command` attachments (`commandMode == "prompt"`), with a fixture row for a kept mid-turn prompt and a dropped task notification | The appendix was missing every prompt typed while Claude was mid-turn (§ 5 E76) | New fixture assertion fails on the pre-fix filter and passes after; full suite 92 passed; appendix regenerated: 81 → 195 prompts across 8 sessions, 0 lines changed above the marker, no sensitive-pattern warnings | § 6 |

---

## 📂 3. Approximate level of AI contribution `[REVIEW]`

The brief asks for an approximate level. The basis for these estimates is the transcript record
(§ 1, § 6): almost every file in this repository was typed by Claude Code in response to a prompt,
and the author's contribution is the direction, the constraints, the decisions in § 4, and the
verification. The shares below are of **typing**, not of judgement — a rough number that the
author must adjust to what they know to be true.

| Component | AI share of the text/code | Who decided what it does |
|---|---:|---|
| `SWD/tools/*.ps1` — extraction, provenance gate, Phase 2 UI automation | ~90% | Author set the safety rules (`CLAUDE.md` § 4) and the scope; AI proposed designs; SQA agents found defects; author signed off security fixes |
| `src/*.py` — the surrogate, splits, baselines, evaluation, prediction API | ~85% | Author chose the problem, the targets, the grouped-by-board split rule and the honest-reporting policy; AI implemented and tuned |
| `tests/` — 92 pytest tests, 67 Pester tests | ~90% | AI wrote them; author reviewed what each asserts |
| `SWD/docs/*.md`, plan files, `README.md` | ~80% | Author directed every document's purpose and reviewed content; AI drafted; humanizer pass on README prose |
| `SWD/data/**` — the dataset | 0% AI | Physics from SWD, a licensed solver. AI wrote the extractor; it never generated a value |
| `AI-USE.md` § 6 — the prompt appendix | 0% AI | Generated from the author's own prompts by `tools/extract_prompts.py` |
| The written report and presentation | to be stated when written | Author |

---

## 📂 4. Decisions that remained mine `[REVIEW]`

Recorded with the prompt that made them (dates as in § 6), so each is traceable:

| Date | Decision | Evidence |
|---|---|---|
| 2026-08-25 | The project itself: a "Virtual Surfer" surrogate trained on ShaperWaveDynamics output, with Board-Jerk and Radicality from Charles et al. (2026) as the performance indicators | Initial commits; `mma3001-project-spec.md` |
| 2026-08-31 | Use the equations from the published paper to constrain what SWD is inferred to compute, rather than reverse-engineering freely | Prompt 2026-08-31 11:42, "Use the equations we got from the scientific article…" |
| 2026-08-31 | Follow the paper's Eq 7 (net displacement) over the spec sheet's arc length for `D` in the Board-Jerk normalisation | `CLAUDE.md` § 7 |
| 2026-08-31 | The metrics document is an internal reference, not a submission | Prompt 2026-08-31 09:37 → 10:21 |
| 2026-08-31 | Start WP3 (the verification scan) before any batch automation; do not build the batch driver until the scan-speed control is proven | Prompt 2026-08-31 10:58; `CLAUDE.md` § 9 gate |
| 2026-09-01 | Separate what was **computed** from what was **extracted**, in a folder of its own, so no derived value can pass as a measurement | Prompt 2026-09-01 11:14 |
| 2026-09-01 | Group every train/test split by board; never train on `elements.csv` rows as if independent | `CLAUDE.md` § 6 |
| 2026-09-02 | Nothing extracted from SWD is ever untracked or deleted from GitHub; only computed views are ignore-listed | Prompt 2026-09-02 (this session) |
| 2026-09-02 | Record every prompt verbatim, harvest every past correction into § 5, and link the review tooling — none of which the brief requires | Prompt 2026-09-02 (this session) |
| 2026-09-14 | Replace graphify with Obsidian, and use Obsidian as the memory layer for every project | Prompts 2026-09-14, "Replace graphify with this" and "Make it so in future all projects use obisidan integration, but as efficiencytly as possible, just for memory" |
| 2026-09-14 | Make this repo a full Obsidian knowledge base (frontmatter, links, a Base-driven worklist), use the Local REST API plugin's built-in MCP server over third-party `mcp-obsidian` servers, and split `CLAUDE.md` into path-scoped rules checked by a rule-inventory diff instead of an SQA run | Answers to the pros/cons questions, 2026-09-14 |
| 2026-09-14 | Share the full vault and its content with a collaborator through GitHub; stay on Obsidian Sync Standard and do not use Sync for this vault | Answers 2026-09-14 ("Full vault + content"; Sync plan cap is the 1 GB) |

**Interview readiness** (`CLAUDE.md` R7 — nothing in the repo I cannot explain unaided). To be
ticked by the author, not by AI:

| Module | Can explain the method | Can explain why this over the alternative | Can explain its failure mode |
|---|:-:|:-:|:-:|
| `src/geometry.py` | ☐ | ☐ | ☐ |
| `src/data.py` | ☐ | ☐ | ☐ |
| `src/splits.py` | ☐ | ☐ | ☐ |
| `src/models.py` | ☐ | ☐ | ☐ |
| `src/physics_baseline.py` | ☐ | ☐ | ☐ |
| `src/evaluate.py` | ☐ | ☐ | ☐ |
| `src/predict.py` | ☐ | ☐ | ☐ |
| `src/profiling.py` | ☐ | ☐ | ☐ |
| `SWD/tools/extract_board.ps1` (provenance gate) | ☐ | ☐ | ☐ |

---

## 📂 5. Errors ledger

Every place the repository's own documents record that an earlier claim, premise, measurement or
piece of reasoning — almost all of it AI-produced — was wrong and was corrected. Harvested on
2026-09-02 by a Claude Code subagent reading 20 documents in full; a sample (E2, E5, E16, E29,
E52) was checked against the sources in the same session. Line references point at the text that
records the correction. "Who caught it" is as stated in the source. Entries E63 onward were made
in the session that created this file. Per `CLAUDE.md` R3, nothing here is ever deleted.

| ID | Date | What was believed | What was true | How it was caught (who) | Recorded at |
|---|---|---|---|---|---|
| E1 | ≤ 2026-08-27 | The board's stored speed field was the speed its hydroscan ran at | It is the GUI speed box as last saved; every scan ran at 20.000 m/s while the stored value ranges 2–20 | Recovering V from the planing mass balance ṁ = ρAV; drag ratio 1.11× where V² would demand 16× (re-measurement) | `SWD/TODO.md:60-99`; `CLAUDE.md` § 6 |
| E2 | 2026-09-01 | ṁ/A = 20463.09 ± 10.68 implied a measured density 1023.154 with a real 0.015 % bias | Density is a 4-entry lookup table; the "mean" was a bimodal mixture of 20460.0 and 20500.0 and the "std" the gap between modes. The 08-27 note that "corrected" the original reading was itself the error | Decompiling `actualiser_fluide()` + re-measuring per board | `CLAUDE.md` § 5; `PROGRESS.md:129-140`. Stale copy still at `SWD/README.md:178-179` |
| E3 | 2026-09-01 | 20.0391 m/s was a second scan speed | 20500/1023 exactly: a ρ = 1025 scan divided by an assumed 1023. One speed, two water temperatures | Same decompile; exact factorisation | `CLAUDE.md` § 5; banner on `what-swd-can-yield.md`, `project-io-spec.md`, three WP3 plans. Stale: `coverage.md:27-33` |
| E4 | 2026-08-31 | SWD's friction model was ITTC-57 or Schoenherr | Blasius + 1/7-power + Schlichting, Re_crit = 5e5; drag ∝ V^1.857, not V² | Decompile of `epaisseur_couche_limite()` + Python reimplementation | `CLAUDE.md` § 5; `PROGRESS.md:150-158` |
| E5 | ~2026-09-01 | The recovered friction law reproduces SWD to 1–3 % median | 7.5 % median | Re-measured over the full corpus when ported to `src/physics_baseline.py` | `TODO.md:163`. The 1–3 % figure still stands at `CLAUDE.md` § 5 and `PROGRESS.md:156` |
| E6 | 2026-09-01 | `actualiser_couche_limite()` uses the stored board speed as friction velocity | Using it gives ratio 0.243 (76 % error); scan speed gives 0.941. SWD overwrites the field before solving | Re-measurement against `_Fx_friction_n` | `TODO.md:138` (D.5). `CLAUDE.md` § 5 still carries the misleading bullet |
| E7 | 2026-08-31 | The `flow ms` box drives the hydroscan; setting 10 would give a second speed | It drives the single-point `Test Position` solver only; all 53 new points recovered ≈ 20.04 | Live driven scan, then independent re-extraction (live run) | `LIVE-RUN-FINDINGS.md:24-38`; `CLAUDE.md` § 9; two plans headed "PREMISE REFUTED" |
| E8 | 2026-08-31 | Speed boxes are `NumericUpDownScanSpeed{1,2,3}kmh`, in km/h; target "36 km/h" | No km/h control exists; the box is an `EDIT` labelled `flow ms`. The planned 36 would have asked for 130 km/h | Live control enumeration | `LIVE-RUN-FINDINGS.md:143-157`; `CLAUDE.md` § 9. Wrong claim still at `BUILD-NOTES.md:104-108` |
| E9 | 2026-08-31 | Drift could be set min/max/step for a cheap 3-angle scan | No such controls; SWD runs its own fixed 11-angle set | Live enumeration | `LIVE-RUN-FINDINGS.md:208-218` |
| E10 | 2026-08-31 | A control that sets hydroscan speed exists and can be found by reading | No such control; enumeration exhaustive | Exhaustive live control-tree enumeration | `SWD/TODO.md:1010-1016`; `CLAUDE.md` § 9 item 2a |
| E11 | 2026-08-31 | "2.7× faster at 10 m/s" (61 s vs 163 s per angle), used to re-base batch cost | Both runs were at ~20 m/s; the difference is board geometry. With a wave loaded (6.59 m/s) not one of 11 angles finished in 11 min | The same live run invalidated its own timing inference (self-caught) | `LIVE-RUN-FINDINGS.md:184-206`; `CLAUDE.md` § 9 |
| E12 | 2026-08-28 | ~95 s per angle, 12–21 min per board, from file timestamps | ~163 s per angle, ~30 min per board; every estimate was ~1.7× too cheap | Timing a full driven scan (live run) | `SWD/TODO.md:715-719` |
| E13 | 2026-08-31 | The target board's unique 22.806 m radius would enter the corpus | SWD's copy branch reset `turn_radius_m` to 100000 and speed 10 → 20; neither a new speed nor a new radius was gained | Re-extraction of the copy after the scan | `LIVE-RUN-FINDINGS.md:43-57`; `CLAUDE.md` § 9 |
| E14 | 2026-08-28 | `default_shortboard_Copy_1` was scaled 1800 → 2000 mm mid-session (a 1.111× homothety) | Not supported: length reads 1800 on the live control and in the title. Cause unknown | `WM_GETTEXT` on the live control, same day | `coverage.md:80-104`. Retracted claim still at `SWD/TODO.md:706-711`, `project-io-spec.md:302-306` |
| E15 | 2026-08-29 | `control-map-scanner-open.csv` held 241 scanner-panel controls vs 165 closed | It is the Fins tab, with zero drift or speed controls; both maps have identical handle sets | Content-diff against a live 166-control map | `SWD/TODO.md:762-774`, item 2 "PREMISE REFUTED" |
| E16 | 2026-08-27 | "Same integrity level as SWD, so UIPI is not the cause"; a stuck `BlockInput` was the blocker | SWD runs High, the shell ran Medium; UIPI was the blocker. "An assumption written down as an observation" | Two diagnostic runs 20 s apart with one variable changed (elevation) | `phase2-hydroscan.md:150-157`; `BUILD-NOTES.md:227-231` |
| E17 | 2026-08-27 | `BlockInput(false)` → error 5 proved another process held an input block | Error 5 is what any non-elevated caller gets; elevated returns lastError 0; `SetCursorPos` succeeds in both | Control run non-elevated with SWD closed | `phase2-hydroscan.md:158-161` |
| E18 | 2026-08-28 | lastError 1460 meant "the send failed"; then, "the click probably landed" | 1460 is ambiguous: two sends to a blocked control both returned 1460 and the click counter read 0 | SQA measurement on an instrumented harness (SQA agent) | `SWD/TODO.md:665-670`; `RESUME.md:119-125` |
| E19 | 2026-08-28 | Two documents said the phase-2 pair "did not run" and "not one line has run against SWD" | True for about an hour on 08-27; sections A–E had run from 12:11 | Re-reading documents against code (self-audit, finding S32) | `BUILD-NOTES.md:18-30`; `RESUME.md:11-12` |
| E20 | 2026-08-27 | `BUILD-NOTES.md` § 4 token/line counts were current | All stale; re-measured 2108/496, 1655/331, 626/102 | SQA re-measurement (`sqa-lead`) | `SQA-FINDINGS.md:205-209`. Response: stop recording them |
| E21 | 2026-08-27 | "165 child windows", carried from a plan narrative | 181 measured; count depends on what is open | `EnumChildWindows` | `BUILD-NOTES.md:239,273` |
| E22 | 2026-08-31 | A WinForms `NumericUpDown` is an `EDIT` plus an `msctls_updown32` buddy | Exactly one `msctls_updown32` exists and it belongs to a tab control | Child-window census in three panel states | `SCAN-FLOW.md:114-120` |
| E23 | 2026-08-26/27 | Fin-polar extraction was complete: "132/132, 0 failures", 340,200 rows | Half the database was silently discarded (every even block): `ReadOuterXml()` + `ReadToFollowing` skip. The lost half held 1 profile and 23 Reynolds numbers found nowhere else | Adversarial SQA review; the run's own success message concealed it (`sqa-lead` round 1) | `SWD/TODO.md:121-126`; `SWD/README.md` § AI Acknowledgment error 2 |
| E24 | 2026-08-26/27 | 13 element columns were data; a null check made fake zeros impossible | Identically zero across 5,914 rows: serialised `Single` fields the hydroscan never assigns. "The original test was literally true and still insufficient" | SQA review + a physical contradiction (element length 0 with wetted length 2,925 mm) | `SWD/TODO.md:127-131`; `CLAUDE.md` § 5; `SWD/README.md` error 3 |
| E25 | 2026-08-26/27 | "These are your own files" justified `BinaryFormatter` over a recursive glob | Seven distinct `shaper_name` values, a `swdshare` directory, cloud-synced | SQA security review measured against the library's metadata (`sqa-security`) | `SWD/TODO.md:133-140`; led to the provenance gate |
| E26 | 2026-08-27 | A −7.9 % performance improvement | Unmeasurable: the E23 fix changed what the program computes (680,400 vs 340,200 rows). No delta | Fixer's self-audit in round 3 | `SWD/TODO.md:226-230`; `SWD/README.md` error 4 |
| E27 | 2026-08-27 | The fixer's rebuttal: the documents root was searched and `swdshare` not found | `swdshare` exists with 29 `ctr*` subdirectories as a sibling of `biblio`; only `biblio\` had been searched | A reviewer checked the claim rather than the reasoning | `SWD/TODO.md:231-235`; `SWD/README.md` "fifth error" |
| E28 | 2026-08-27 | A fixture tested three non-ASCII profile names | `,` binds tighter than `+` in PowerShell: one 19-character string, and nothing read a profile back | Fixer's self-audit of its round-1 tests | `SWD/TODO.md:236-239` |
| E29 | 2026-08-27 | The containment guard added in rounds 2–3 protected `-OutDir` | A tilde-spelled `-BiblioPath` silently disabled containment (`Test-Path -LiteralPath` resolves `~`, `GetFullPath` does not) | Independent verifier demonstrated it live by deleting a decoy file (fresh `sqa-lead`) | `SWD/TODO.md:258-282` — a hole introduced by the fix rounds themselves |
| E30 | 2026-08-28 | The path guard was safe after swapping to `GetUnresolvedProviderPathFromPSPath` | 8.3 short names defeated it: `SHAPER~1` was ALLOWED. Third occurrence of the path-canonicalisation class | SQA loop (SQA agent) | `SWD/TODO.md:609-612`; `RESUME.md:157-161` "do not write a fifth" |
| E31 | 2026-08-28 | `Test-SwdWritableTarget` protected the real library | Documents is redirected to OneDrive and matched none of its four candidate paths | SQA loop | `SWD/TODO.md:617-618` |
| E32 | 2026-08-28 | `-WhatIf` was a safe rehearsal (asserted twice in the file's own comments) | `-WhatIf` clicked the live application; `Invoke-SwdButton` lacked `SupportsShouldProcess` | SQA loop | `SWD/TODO.md:606-608`; `SQA-FINDINGS.md` W11 |
| E33 | 2026-08-27 | The click probe and the diagnostic's verdict lines could be trusted | Five of six Criticals were "instruments reporting a state they never achieved or never measured"; `BM_GETCHECK` is blind on the controls SWD is made of | Full SQA fan-out against a throwaway WinForms harness (`sqa-lead` + three specialists) | `SWD/TODO.md:546-551`; `SQA-FINDINGS.md:25-62` |
| E34 | 2026-08-28 | "0 of 12 boards vary internally" in turn radius was a thin-corpus artefact | It is a property of the file format: radius is per-board metadata, 13 of 13 | Controlled hydroscan then re-extraction (live run) | `SWD/TODO.md:690-698`; `coverage.md:65-78`; `CLAUDE.md` § 6 |
| E35 | ~2026-08-26 | Trajectory speed and turn radius were absent from the data | Present; the conclusion came from one board and `[NonSerialized]` zeros read as real | Full-corpus measurement | `SWD/README.md` § AI Acknowledgment error 1 |
| E36 | undated | Element 0's `nom='global'` marked an aggregate row, so `operating_points.csv` double-counts | All 467 elements carry the same strings; constant metadata | Census over all elements | `PROGRESS.md:105-109` |
| E37 | undated | Derived incidence asin(S/(L·w)) equals SWD's stored incidence | Median difference −0.58°, σ 3.71°, 36.6 % agree within 0.5° | Direct comparison | `PROGRESS.md:111-118` |
| E38 | undated | Trajectory model gave Ra = 0.0096 rad²/s | Ra = 0.702; `np.sign` returns 0 at an exact zero, collapsing the window to one sample | Implausible value chased to root cause (self-caught) | `PROGRESS.md:120-127` |
| E39 | undated | A verifier's proposal: read `temperature_eau` off a `.fynbs` to make V_REF a measurement | No such field among `Class_surfboard`'s 231; it lives only in global settings. V_REF stays an inference | Field census cross-check | `PROGRESS.md:159-171` |
| E40 | 2026-08-31 | 58 `Single.MaxValue` sentinels in `element_width_mm` | 68 after the corpus grew to 6,867 rows | Re-measurement | `project-io-spec.md:139-141`; owed D.4 |
| E41 | 2026-08-31 | `Board_Sample.txt` is 148 rows | 296 lines alternating data / hex echo of the line above, 148 of 148 | Reading inside the archives | `SWD/TODO.md:884-888`; `CLAUDE.md` § 9 |
| E42 | 2026-08-31 | All three supplementary files start at t = 225 s | `mmc1` is a board-side ms counter, own epoch, running backwards, non-uniform | Reading inside the archives | `SWD/TODO.md:889-892`; `performance-metrics.md` § 10.5 |
| E43 | 2026-08-31 | Eight usable EMG channels | `L.Semitend.` holds one value across 20,001 rows; seven usable | Reading inside the archives | `SWD/TODO.md:893-896`; `performance-metrics.md` § 10.4 |
| E44 | 2026-08-31 | IMU channel identities were recoverable from the file | No header; 91 data columns, identities not recoverable | Reading inside the archives | `SWD/TODO.md:897-898` |
| E45 | 2026-08-31 | Table 9 could be parsed from the PDF | Extraction drops the decimal comma in Table 9 only (`-0,123` → `-0123`); all 40 cells reconstructed and verified instead | Self-consistency audit against Tables 4–8 | `SWD/TODO.md:1096-1100` |
| E46 | 2026-08-31 | Charles et al. define two metrics | Seventeen equations plus a five-phase wave decomposition | Reading the article directly | `SWD/TODO.md:1036-1041`; `performance-metrics.md` |
| E47 | ~2026-09-01 | The +0.52 R² was the model's generalisation score | It is pooled, log-space, friction only; the same predictions score −0.485 per-fold in newtons | Re-scoring under both conventions | `TODO.md:160-161`; `README.md` § 5 |
| E48 | undated | SWD's drag components sum to the total | 0 of 720 rows match; median residual +0.25 % | Arithmetic over the corpus | `TODO.md:162`; `README.md` § 5 |
| E49 | undated | SVR at −0.265 on stock defaults meant the method was unsuitable | A property of the defaults: 339 of 389 rows were support vectors. Nested tuning gives +0.521 | Nested grouped CV | `README.md` § 5 |
| E50 | 2026-09-02 | Two SQA rounds had passed `swd_board.ps1`'s array handling | `return ,$out` into `Where-Object` makes `$_` the whole array; `.Count` returned 1 for two results. The test stub was more forgiving than the real function | Found by the fixer itself in round 3 (`code-reviewer`) | `TODO.md:169-176` |
| E51 | 2026-09-02 | Three tests pinned the behaviours they were named for | All three passed for the wrong reason (null coerced to `''`; a throw from the wrong place; a homoglyph admitted under either comparison) | Mutation sweep | `TODO.md:177-185` |
| E52 | 2026-09-02 | The mutation harness had restored every file; two failing tests were the tests' fault | Mutant M5d sat live in `swd_board.ps1` for ~25 min; the integrity check compared against a remembered count (5) instead of a measured one (6). The tests were right | The test suite, once believed | `TODO.md:187-207` |
| E53 | 2026-09-02 | Linguistic `-eq` at `swd_board.ps1:450` might be exploitable | Not exploitable: all 973 BMP case pairs swept, `-eq` is invariant-culture | Exhaustive sweep (verifier) — a suspicion refuted | `TODO.md:209-215` |
| E54 | 2026-08-28 | The modal-dialog safety gate matched dialog text | `Get-SwdDialogControl` never populated `Text`; the gate would have refused everything, for the wrong reason | New Pester tests, before anything touched SWD | `SWD/TODO.md:808-816` |
| E55 | 2026-08-28 | Scripted edits preserved line endings | `write_text` converted the file to mixed CRLF/LF (1160 + 171) | Byte inspection (self-caught) | `SWD/TODO.md:818-824` |
| E56 | 2026-08-27 | The containment harness's six failures meant the guard refused everything | The script died before the guard ran: a space in the sandbox path split `-ArgumentList` | Investigating why the control case also failed (self-caught); "second time this exact trap has appeared" | `SWD/TODO.md:289-295` |
| E57 | 2026-08-27 | The parked security patch was ready to apply as written | Two defects: a write target outside containment, and the username/tenant leak reintroduced. "A parked patch ages against a moving codebase" | Checked against invariants added in later rounds (independent verifier) | `SWD/TODO.md:357-363` |
| E58 | 2026-08-27 | The diagnostic's log and control map were UTF-8; section A's integrity reading was reliable | Log was UTF-16LE with BOM; CSV had a UTF-8 BOM; section A contradicted section B in the same report | Byte inspection + SQA W9 | `SWD/TODO.md:528-535`; `SQA-FINDINGS.md:79-82` |
| E59 | 2026-09-02 | `Get-FileHash` is always available under `powershell.exe` | Absent when 5.1 inherits a pwsh-7 `PSModulePath` | The driver's own tests, before the live run | `TODO.md:77-85` |
| E60 | undated | `graphify update .` keeps the graph current | Code half only (75 of 289 nodes); a rebuild clears the flag so `check-update` reports all-clear on a stale graph | Reading `watch.py:_rebuild_code` | `CLAUDE.md` § graphify |
| E61 | 2026-08-31 | `'*more than 60 mn*'` in the test suite was evidence of the real dialog | It traces to a synthetic label in a throwaway harness and was never matched against SWD; there are at least three scan-flow dialogs, two with `&Yes`/`&No` | Live dialog capture (live run) | `SCAN-FLOW.md:53-63`; `LIVE-RUN-FINDINGS.md:159-172` |
| E62 | 2026-08-27 | Several defects suspected during the SQA fan-out (GDI leaks, `PrintWindow` fallback, format-string abuse, a half-committed control) | All refuted by measurement and recorded so they are not re-raised | Two independent specialists (SQA agents) | `SQA-FINDINGS.md:167-182` |
| E63 | 2026-09-02 | `CLAUDE.md` § 2's seven-row weighted rubric (10/10/10/20/25/15/10), cited to the brief | The brief's rubric has six criteria and no weights; the table came from `mma3001-project-spec.md`, an AI-compiled sheet | Reading the PDF text directly (this session) | `CLAUDE.md` § 2 |
| E64 | 2026-09-02 | "A withheld test split of at least 20 %, with RMSE / MAE / R²" was a brief requirement | Neither "20 %" nor "RMSE" appears in the brief; withheld data is one of ten listed validation routes | Full-text search of the PDF (this session) | `CLAUDE.md` § 2 |
| E65 | 2026-09-02 | This session's plan stated "Nothing in the repo records AI use" | `SWD/README.md` § AI Acknowledgment has existed since 2026-08-27 and names five errors; the gap was the ML half and the repo root | The harvest subagent's citation of `SWD/README.md:343-358` | this file, § intro |
| E66 | 2026-09-02 | README § 8 draft: "In every round above the fixing agent's own verdict was `Critical=0 \| Warning=0`" | The extraction loop's fixer reported one Warning; the UIA row had no verifier yet as drafted. Rewritten to the rounds it is true of | Re-reading the draft against its own table (self-caught during the style pass) | `README.md` § 8 |
| E67 | 2026-09-02 | README § 8 draft: the UIA loop's verifier was "not yet run" | Two verifier rounds exist: `C=2 W=6 S=9` and `C=0 W=2 S=13`; the draft was written from `TODO.md` read only to line 45 | The harvest subagent's table | `README.md` § 8 |
| E68 | 2026-09-14 | Obsidian's docs and both outside AI reports (Gemini, Fable): "the first CLI command launches Obsidian" | On 1.13.7 under Windows, with the app closed, `obsidian version` printed "The CLI is unable to find Obsidian" and exited 1; nothing launched | Running the command (this session) | `.claude/skills/obsidian-memory/SKILL.md` § 1 |
| E69 | 2026-09-14 | Gemini report: GitHub Free includes 1 GB of Git LFS storage and bandwidth | GitHub's billing docs list 10 GiB storage and 10 GiB bandwidth for Free | Research subagent reading docs.github.com | not adopted |
| E70 | 2026-09-14 | Gemini report: resolve sync conflicts automatically with `git pull -X theirs` | That strategy silently discards local edits on every conflicting hunk; unsafe for memory notes or coursework | Review of the recommendation against git's documented behaviour | not adopted |
| E71 | 2026-09-14 | Fable report: the Windows trap is WSL calling `Obsidian.exe` | This machine runs Claude Code natively; the trap that applies is Git Bash resolving `obsidian` to the GUI `.exe`, where colon commands exit 127 with no output (measured); `Obsidian.com` works | Running both invocations (this session) | `~/.claude/CLAUDE.md`; skill § 1 |
| E72 | 2026-09-14 | Fable report: Obsidian + graphify setups give "up to 71.5× fewer tokens" | The figure is graphify's own estimate (characters ÷ 4) against pasting the whole corpus into context, which Claude Code does not do; 8.8× on code alone; no measured API usage | Research subagent reading `graphify/benchmark.py` and the worked example | not adopted |
| E73 | 2026-09-14 | This session's plan: the `CLAUDE.md` split would take it from ~30 KB to ~16 KB | Measured 19,140 B: the pointers, links and new memory section cost more than estimated | `wc -c` after the split | `CLAUDE.md` |
| E74 | 2026-09-14 | First draft of `obsidian-memory` SKILL.md frontmatter | `when_to_use` was invalid YAML (comma-separated quoted strings), which would have loaded the skill with empty metadata | `yaml.safe_load` in the skill-builder quality gate (self-caught) | skill frontmatter |
| E75 | 2026-09-14 | graphify's installed `CLAUDE.md` section and hooks: "MANDATORY: run `graphify query` before grepping" as the efficient route | The graph was last built 2026-09-02 and its prose half never refreshed; the hooks fired ~350 times across 8 sessions, each pointing at the stale graph | Counting hook injections in the session transcripts (this session) | graphify removed |
| E76 | 2026-09-14 | § 6 prompt appendix, generated since 2026-09-02: "every prompt verbatim" | 114 prompts across all 8 sessions were missing. Prompts typed while Claude is mid-turn are stored as `queued_command` attachments, not `type == "user"` records, and the extractor read only the latter | Regenerating the appendix and finding this session's mid-turn prompts absent; counted across all transcripts (self-caught) | `tools/extract_prompts.py`, § 6 |

**Corrected claims still standing in the source documents** (the ledger records; it does not
fix — each needs its own change, in which R3 applies): `SWD/README.md:178-179` (withdrawn
1023.154 figure), `CLAUDE.md` § 5 (1–3 % where 7.5 % was measured; the friction-velocity bullet
E6), `coverage.md` (667 rows / 27 boards / "2 speeds"), `SWD/TODO.md:706-711` and
`project-io-spec.md:302-306` (retracted homothety), `project-io-spec.md:130` and
`DATA-DICTIONARY.md:33-36` (sentinel count), `BUILD-NOTES.md:104-108` (the km/h control). The
first four are listed in `TODO.md` under "Documentation corrections owed".

---

## 📂 6. Prompt appendix

Every prompt given to Claude Code for this repository, verbatim, recovered from the session
transcripts Claude Code keeps outside the repo. Regenerate with `python tools/extract_prompts.py`;
the home directory is redacted to `~`. Nothing between the markers is edited by hand.

<!-- prompts:begin -->
195 prompts across 8 sessions, 2026-08-26 to 2026-09-14. Timestamps are as recorded by Claude Code (UTC). Generated by `tools/extract_prompts.py`; do not edit by hand.

| Session | First | Last | Prompts | Claude Code | Model |
|---|---|---|---:|---|---|
| `50a19d62` | 2026-08-31 11:29 | 2026-09-02 12:08 | 49 | 2.1.251, 2.1.252, 2.1.258 | <synthetic>, claude-opus-5 |
| `5fa83184` | 2026-08-30 11:08 | 2026-08-30 11:08 | 1 | 2.1.251 | claude-opus-5 |
| `9865a2c3` | 2026-08-30 11:09 | 2026-08-30 11:41 | 5 | 2.1.251 | claude-opus-5 |
| `abc4f67c` | 2026-09-02 00:03 | 2026-09-02 00:15 | 6 | 2.1.258 | claude-fable-5-1, claude-opus-5 |
| `c253c200` | 2026-08-26 12:38 | 2026-08-26 23:45 | 34 | 2.1.246 | claude-opus-5 |
| `d5967321` | 2026-08-27 01:21 | 2026-08-29 07:43 | 43 | 2.1.247, 2.1.250 | claude-opus-5 |
| `daa5cecd` | 2026-09-14 07:07 | 2026-09-14 07:25 | 7 | 2.1.270 | claude-opus-5 |
| `ffb0c7d3` | 2026-08-31 07:15 | 2026-08-31 11:24 | 50 | 2.1.251 | claude-opus-5 |

### 2026-08-26 12:38 · `c253c200` · `main`

> Do some research to find out whether the MCP: https://www.mecaflux.com/suite/en/pass_mcp.php, can be used for ShaperWaveDynamics software already purchased on my laptop, if it helps, you can access the files.

### 2026-08-26 12:39 · `c253c200` · `main`

> Mecaflux has https://www.mecaflux.com/hydrodynamique.htm SWD as a branch of its products I believe

### 2026-08-26 12:39 · `c253c200` · `main`

> This is the website: https://surfhydrodynamics.com/

### 2026-08-26 12:40 · `c253c200` · `main`

> The goal is for an output of csv / array that can be used for machine learning

### 2026-08-26 12:40 · `c253c200` · `main`

> They should include information on: Trajectory speed, Float64 array, m/s, domain [0.0, 10.0m/s]
> Roll angle: Float64 array, radians [-pi/3,pi/3]
> Tabulated discrete reference coordinates from SWD, inc. mapping velocity, roll and curve radius and drag forces
> Trajectory curve radius, all provided by SWD

### 2026-08-26 12:42 · `c253c200` · `main`

> Using these into this report: https://www.sciencedirect.com/science/article/pii/S2590123025049114, to calculate Board-Jerk index, and 'Radicality'

### 2026-08-26 12:45 · `c253c200` · `main`

> I have also included a file with the end goal of fin sensor pcb using IMU ICM-20948. The data will be modelled then used for simplifying this pcb code much later on, but the focus for now is the machine learning

### 2026-08-26 12:54 · `c253c200` · `main`

> I have supplied the pdf

### 2026-08-26 12:54 · `c253c200` · `main`

> + 2 markdown files giving context to my unit and to the project specifically

### 2026-08-26 12:55 · `c253c200` · `main`

> Make sure that there would actually be enough data points to use for machine learning, do some research on how machine learning works to figure this out

### 2026-08-26 12:57 · `c253c200` · `main`

> Further, it may be difficult to carry out the process of synthesising data manually, so do some research on how the software actually works, what it runs on, and how you can utilise that for this process.

### 2026-08-26 12:58 · `c253c200` · `main`

> The priority should be making sure this process does not corrupt the software, as it is expensive

### 2026-08-26 12:58 · `c253c200` · `main`

> But this has been my only found use for it so far so don't sacrifice efficacy for this to be the case.

### 2026-08-26 12:59 · `c253c200` · `main`

> Just carry out deep research to see if anything is possible in extracting the required data points we have discussed into enough data for machine learning in the project brief

### 2026-08-26 13:01 · `c253c200` · `main`

> Find out how the storage files work and if you would be able to sample data and create you own ones, or if they have equations that are readable that you could use their existing data to make the required inputs

### 2026-08-26 13:04 · `c253c200` · `main`

> It is not necessarily a correction, just a possible direction you could go in carrying out the goal

### 2026-08-26 13:19 · `c253c200` · `main`

> Also, there are certain boards that the app has saved, with hydroscans already available, if these are not what you have already found, have a look at them , because they may have extra information on what could be used, and what data is available

### 2026-08-26 13:28 · `c253c200` · `main`

> Also, have a look at the folder just added to this directory labelled Project, which includes the project overview, and what the unit requires for AI documentation and reporting, make sure you adhere to these when you explain the processes that occurred here, in the SWD folder you make, have it in the form they like

### 2026-08-26 13:30 · `c253c200` · `main`

> Also make a CLAUDE.md file for this directory explaining the requirements for the project, so claude will adhere to it throughout

### 2026-08-26 13:31 · `c253c200` · `main`

> This pplan will have a lot of steps so ensure you incorporate the use of a todo list too

### 2026-08-26 13:42 · `c253c200` · `main`

> Make sure not to have any questions, if there are any, just go with recommended option, as you describe it, I will be sleeping

### 2026-08-26 22:11 · `c253c200` · `main`

> Fix the problem with the Binary Formatter gate

### 2026-08-26 22:33 · `c253c200` · `main`

> Reapprove then carry out phase 2

### 2026-08-26 22:45 · `c253c200` · `main`

> Try the input mechanisms again, I have stopped controlling screen myself

### 2026-08-26 22:52 · `c253c200` · `main`

> As in should I close the app?

### 2026-08-26 22:53 · `c253c200` · `main`

> done, rerun it

### 2026-08-26 22:56 · `c253c200` · `main`

> Well carry out the rest of the process (phases 3 and 4) and we can work on this bit later then.

### 2026-08-26 23:10 · `c253c200` · `main`

> Do some research on what could have gon wrong in the automation of the SWD software, inclduing what it runs on, how it works, explore may also be useful for this. Also try and figure out some other options on how to acquire the rest of the data required

### 2026-08-26 23:17 · `c253c200` · `main`

> The ideal would be the ability to extract these rol angles, and traj radii, and drag forces, over a large number of speeds

### 2026-08-26 23:19 · `c253c200` · `main`

> Make a md file for SWD that extracts all possible metrics for surf performance from the articvle in this directory, that we could use for the project,

### 2026-08-26 23:19 · `c253c200` · `main`

> There should be more than the two i meantioned

### 2026-08-26 23:27 · `c253c200` · `main`

> Download everything needed and place into the SWD folder

### 2026-08-26 23:27 · `c253c200` · `main`

> on this directory

### 2026-08-26 23:45 · `c253c200` · `main`

> Im going to save this plan for later use, as I need to study, can you put everythkng into the plan, and I can work on thsi later. The plan will include getting phase 2 data out

### 2026-08-27 01:21 · `d5967321` · `main`

> Coudl you open up the most recent plan we had created?

### 2026-08-27 01:24 · `d5967321` · `main`

> Also remove it from the original plan so i can pick up the wp1 and wp2 at a later date

### 2026-08-27 01:25 · `d5967321` · `main`

> Do some deep research and exploration to see if there are available headless operatives for a software of this type

### 2026-08-27 01:26 · `d5967321` · `main`

> And how they could be harnessed.

### 2026-08-27 01:26 · `d5967321` · `main`

> Only use if these last processes are not working

### 2026-08-27 01:30 · `d5967321` · `main`

> If you find out it works better, this should be the first option

### 2026-08-27 01:48 · `d5967321` · `main`

> Note down the process in producing any code so that I can run through sqa later (ps1 and py)

### 2026-08-27 02:00 · `d5967321` · `main`

> Create a todo list for these processes, include when to do sqa run (only one run not a full loop)

### 2026-08-27 02:09 · `d5967321` · `main`

> How should the UAC prompt appear?

### 2026-08-27 02:11 · `d5967321` · `main`

> I did not see a uac, should i try again?

### 2026-08-27 02:13 · `d5967321` · `main`

> A prompt surfaced

### 2026-08-27 02:13 · `d5967321` · `main`

> I clicked allow

### 2026-08-27 03:00 · `d5967321` · `main`

> Why are you not using code-reviewer for this?

### 2026-08-27 03:06 · `d5967321` · `main`

> Actually, I need to begin a test soon, so cancel the code-reviewer, and I will return later to carry out the rest of the process. Make sure everything is easily picked up from a fresh context

### 2026-08-27 09:18 · `d5967321` · `main`

> Continue it please! I used claude --resume, so can now access the exact chats

### 2026-08-27 09:33 · `d5967321` · `main`

> Make this a full SQA-loop, then we can carry out the rest

### 2026-08-27 09:36 · `d5967321` · `main`

> Yes the goal class is functionality, but make it so the sqa-functional is the only subagent spawned by sqa-lead for this process, I just want this to work, and be done asap

### 2026-08-27 10:16 · `d5967321` · `main`

> Also for this SQA, when code-reviewer is spawned, can the fixes be split up among three separate code-reviewers each time?

### 2026-08-27 10:18 · `d5967321` · `main`

> ok stick with one fixer per round

### 2026-08-27 12:57 · `d5967321` · `main`

> Can you check that auto-restart for claude code with a usage limit hit will work in this session, I have just updated settings json

### 2026-08-27 19:03 · `d5967321` · `main`

> SWD is open now

### 2026-08-27 19:07 · `d5967321` · `main`

> I was not looking, try again and I can watch SWD

### 2026-08-27 19:10 · `d5967321` · `main`

> There is a check before the hydroscan completes, it is now running bc I clicked agree

### 2026-08-27 19:10 · `d5967321` · `main`

> It says "it takes more than 60 nm do you want to proceed" or something, and you need to press ok

### 2026-08-27 19:11 · `d5967321` · `main`

> Not now

### 2026-08-27 19:11 · `d5967321` · `main`

> It did

### 2026-08-27 19:11 · `d5967321` · `main`

> Thats for future so you can click it yourself not me

### 2026-08-27 19:46 · `d5967321` · `main`

> Hydroscan done, what steps are there to do and how long will it take?

### 2026-08-27 19:57 · `d5967321` · `main`

> Go for it

### 2026-08-27 19:57 · `d5967321` · `main`

> Make a todo list to stay on track

### 2026-08-27 22:08 · `d5967321` · `main`

> Did this get done?

### 2026-08-27 23:00 · `d5967321` · `main`

> Closed!

### 2026-08-28 00:33 · `d5967321` · `main`

> Yep do the verification scan at 36 km/h once SQA clears

### 2026-08-28 00:42 · `d5967321` · `main`

> Sounds good, lay out for me what I would need to do

### 2026-08-28 10:01 · `d5967321` · `main`

> After that is corrected, dont run a fresh pass. Carry out all else you described

### 2026-08-29 07:12 · `d5967321` · `main`

> I have opened 2003 Taylor knox channel island boardm there is no hydroscan for this board.

### 2026-08-29 07:26 · `d5967321` · `main`

> Have a look at the plan and todos to see exactly what needs to be done

### 2026-08-29 07:33 · `d5967321` · `main`

> The plan is to have a look at all boards, and for you to run this, I believe it is step 7 in todo.md

### 2026-08-29 07:34 · `d5967321` · `main`

> You first wanted me to opemn this board

### 2026-08-29 07:35 · `d5967321` · `main`

> We have been building this so that it would be safe

### 2026-08-29 07:36 · `d5967321` · `main`

> Make sure you are getting all required information from the boards for the project

### 2026-08-29 07:41 · `d5967321` · `main`

> Will this use a lot of tokens or is it mostly hands off?

### 2026-08-29 07:43 · `d5967321` · `main`

> Board automation has been produced i believe but not atempted, the plan was to try it on this board

### 2026-08-30 11:08 · `5fa83184` · `main`

> Have a look at the repo to ensure you make use of all aspects: https://github.com/Graphify-Labs/graphify

### 2026-08-30 11:09 · `9865a2c3` · `main`

> Have a look at the github here: https://github.com/Graphify-Labs/graphify, to help figure out how it works

### 2026-08-30 11:10 · `9865a2c3` · `main`

> Also do a little research on how it can be used, including last30days, to see what creative ways it has been adopted in

### 2026-08-30 11:11 · `9865a2c3` · `main`

> Put the findings of how it can be used well into global CLAUDE.md so for other directories I can do the same

### 2026-08-30 11:39 · `9865a2c3` · `main`

> Does this automatically update?

### 2026-08-30 11:41 · `9865a2c3` · `main`

> As in does the graphify automatically update as i use the directory given its main function is for memory

### 2026-08-31 07:15 · `ffb0c7d3` · `main`

> What needs to be done next for this?

### 2026-08-31 07:16 · `ffb0c7d3` · `main`

> claude.md in this project should have some idea

### 2026-08-31 07:17 · `ffb0c7d3` · `main`

> Use the graphify to understand where the code sits

### 2026-08-31 07:31 · `ffb0c7d3` · `main`

> Move on to the next item

### 2026-08-31 07:35 · `ffb0c7d3` · `main`

> Was there another headless ps1 file that was needing to be made too?

### 2026-08-31 07:35 · `ffb0c7d3` · `main`

> That would switch between boards?

### 2026-08-31 07:35 · `ffb0c7d3` · `main`

> Or was this to be done later?

### 2026-08-31 07:42 · `ffb0c7d3` · `main`

> And the board

### 2026-08-31 07:45 · `ffb0c7d3` · `main`

> it's up, the dialog is showing

### 2026-08-31 07:48 · `ffb0c7d3` · `main`

> Clicked yes, read what it says now

### 2026-08-31 07:50 · `ffb0c7d3` · `main`

> Clicked yes, it said that a new one was made, and now has it in a new file, somewhere in OneDrrive it said

### 2026-08-31 07:50 · `ffb0c7d3` · `main`

> Now I am back onto the original screen

### 2026-08-31 07:51 · `ffb0c7d3` · `main`

> And will be able to press Hydrodynamics scanner again

### 2026-08-31 07:52 · `ffb0c7d3` · `main`

> Before I do this, note this down for the headless process to understand as a part of the process

### 2026-08-31 07:53 · `ffb0c7d3` · `main`

> I have pressed hydrodynamics scanner again, and now have the message you expected before

### 2026-08-31 08:00 · `ffb0c7d3` · `main`

> cancelled it, set the speed

### 2026-08-31 08:11 · `ffb0c7d3` · `main`

> You can click it

### 2026-08-31 08:20 · `ffb0c7d3` · `main`

> Surfer mass is at 50kg, was this on purpose?

### 2026-08-31 08:21 · `ffb0c7d3` · `main`

> Also, the starting hydroscan tab is still showing up

### 2026-08-31 08:21 · `ffb0c7d3` · `main`

> Note down any errors you find witht he running that you can use for sqa later

### 2026-08-31 08:39 · `ffb0c7d3` · `main`

> load a wave and check the speed then

### 2026-08-31 08:43 · `ffb0c7d3` · `main`

> loaded a wave, check it now

### 2026-08-31 08:56 · `ffb0c7d3` · `main`

> Keep testing until you have a full understanding of all the data that can be extracted from this software

### 2026-08-31 09:03 · `ffb0c7d3` · `main`

> It was already on that screen

### 2026-08-31 09:03 · `ffb0c7d3` · `main`

> Wait nvm

### 2026-08-31 09:04 · `ffb0c7d3` · `main`

> I am now on the Test Position view on the right, with the Dialog showing up again

### 2026-08-31 09:06 · `ffb0c7d3` · `main`

> I dont know how to unload a wave

### 2026-08-31 09:10 · `ffb0c7d3` · `main`

> Now you know exactly what you can extract from this, use this to figure out what inputs I can use for the project, and how this relates to the equations mentioned in the article (these have all been summarised by various md files.

### 2026-08-31 09:10 · `ffb0c7d3` · `main`

> The goal is a wide range of values, with something applicable to my icm 20948

### 2026-08-31 09:10 · `ffb0c7d3` · `main`

> you could also use the research paper as a background to what you'd need

### 2026-08-31 09:11 · `ffb0c7d3` · `main`

> as in the research paper data they gave

### 2026-08-31 09:12 · `ffb0c7d3` · `main`

> Also do some research on magnetometer this should be truseted as it is very important for understanding movement

### 2026-08-31 09:13 · `ffb0c7d3` · `main`

> Have a look at various pressure sensors too, there may be one mentioned in the pcb sheet I gave, do deep research on how they work and see if the data from this SWD could be integrated into it

### 2026-08-31 09:13 · `ffb0c7d3` · `main`

> The primary goal though is to ensure that it fits into the requirements for the assignment

### 2026-08-31 09:14 · `ffb0c7d3` · `main`

> When this is all done, update the plans to include this process

### 2026-08-31 09:14 · `ffb0c7d3` · `main`

> Update the plans to include the individual data that we need I mean, as well as the previously decided data**

### 2026-08-31 09:16 · `ffb0c7d3` · `main`

> Dont make this decided data the only data, these ar ejust ideas you are making

### 2026-08-31 09:17 · `ffb0c7d3` · `main`

> I want to be able to decided myself

### 2026-08-31 09:17 · `ffb0c7d3` · `main`

> Put them in the terms of the paper (so can be carried over relatively easily)

### 2026-08-31 09:19 · `ffb0c7d3` · `main`

> Also, work with your newfound understanding of the app, to see if it can be manipulated in any other way to other data sources

### 2026-08-31 09:32 · `ffb0c7d3` · `main`

> Now what needs to be done?

### 2026-08-31 09:35 · `ffb0c7d3` · `main`

> What is WP2?

### 2026-08-31 09:37 · `ffb0c7d3` · `main`

> Is it purely for CLAUDE to use? Or are you suggesting i would submit it?

### 2026-08-31 10:21 · `ffb0c7d3` · `main`

> Write it as an internal reference with the label

### 2026-08-31 10:23 · `ffb0c7d3` · `main`

> Plan the whole WP2 out and all required aspects of it

### 2026-08-31 10:41 · `ffb0c7d3` · `main`

> Fix the hardcoded test paths and the remaining leaks

### 2026-08-31 10:53 · `ffb0c7d3` · `main`

> Make the switch

### 2026-08-31 10:58 · `ffb0c7d3` · `main`

> Lets start with WP3

### 2026-08-31 10:58 · `ffb0c7d3` · `main`

> Do a full audit to figure out what needs to be dine

### 2026-08-31 11:24 · `ffb0c7d3` · `main`

> Ive closed it

### 2026-08-31 11:29 · `50a19d62` · `main`

> Could you do some deep research on how exe files work, use this info to figure out what the SWD uses to actually calculate planing, and trajectory velocity, hopefully we could use their equations to output our own data. It should include board shape, and weight of surfer for example, do afull audit on the application

### 2026-08-31 11:37 · `50a19d62` · `main`

> Would you be able to extract if the information was not uploaded to github?

### 2026-08-31 11:40 · `50a19d62` · `main`

> Use what the project needs

### 2026-08-31 11:42 · `50a19d62` · `main`

> Actually no

### 2026-08-31 11:42 · `50a19d62` · `main`

> Use what the article equations are

### 2026-08-31 11:42 · `50a19d62` · `main`

> That should act as the scope for what you should be extracting

### 2026-08-31 11:43 · `50a19d62` · `main`

> No, i need to reword it, I think you misunderstood

### 2026-08-31 11:44 · `50a19d62` · `main`

> Use the equations we got from the scieintific article to narrow down the equations SWD uses to only those which can be used in the performance context.

### 2026-08-31 12:13 · `50a19d62` · `main`

> make a todo list to keep on track

### 2026-08-31 12:22 · `50a19d62` · `main`

> When this is all done, and the ps1 files have been built, for any that require it run SQA loop on them, add this to the todo

### 2026-09-01 09:43 · `50a19d62` · `main`

> So, during this whole process, I have begun to become a bit lost in what it is we have actually been able to do. Could you explain to me, what we have be able to extract, and what we have been able to compute for the default shortboard. Also what we have been able to extract and what we have been able to compute (or would be able to) from the SWD app itself

### 2026-09-01 09:44 · `50a19d62` · `main`

> Just procure an explanation for me that would reside in this chat

### 2026-09-01 09:51 · `50a19d62` · `main`

> Great, from the data we have found. Again firstly from default shortboard, then overall SWD, what can I use for my PCB?

### 2026-09-01 09:51 · `50a19d62` · `main`

> Again make it into a response in the chat as an output

### 2026-09-01 11:14 · `50a19d62` · `main`

> Sort all data not extracted, and instead computed, into a folder (in its current folder), labelled computer data

### 2026-09-01 12:16 · `50a19d62` · `main`

> This was produced by claude so raise any questions you have if necessary:# Task: Board-Geometry ML Surrogate — Data Generation + Model Pipeline
>
> ## The goal in one paragraph
>
> Build a machine-learning surrogate for my MMA3001 project that takes **board geometry + operating condition** as inputs and predicts the **board's force response** as output. The physics ground truth comes from SWD (Shaper Wave Dynamics), whose hydroscans are slow (~12 min per board). The surrogate replaces the slow solver so a board's forces can be predicted instantly. To learn geometry effects properly we need many more board variants than the ~29 currently extracted, so a second goal is to **automate the generation of board geometry variants** in SWD's Shape Room, hydroscan each one, and extract the results into the training table.
>
> Work through this with me step by step. Do not skip the verification steps.
>
> ---
>
> ## 1. The ML specification (agreed design — do not change without asking)
>
> **Inputs (features), one row per operating point:**
>
> | Feature | Type | Units | Source |
> |---|---|---|---|
> | Board geometry: volume, total mass, foam mass, length, width | float64 | L, kg, kg, mm, mm | extracted per board (`boards.csv` + extraction) |
> | `drift_deg` | float64 | degrees | operating point |
> | roll angle (mean roll of the roll case) | float64 | rad or deg — pick one, document it | operating point |
>
> **Targets (outputs), predicted per operating point:**
>
> | Target | Units | Notes |
> |---|---|---|
> | `Fx_friction_n` (friction drag) | N | has a physics baseline — see §5 |
> | `Fx_planing` (planing drag) | N | |
> | `Fx_rail_n` (rail drag) | N | can legitimately be **negative** (thrust) — do not clip |
> | `Fz_planing_n` / lift | N | |
> | total drag | N | predict directly AND as sum of components — see §5 |
>
> - Use **separate models per target** (SVR is single-output anyway), plus one multi-output
>   decision tree as the structural alternative for comparison.
> - Pipeline: `StandardScaler` + regressor, wrapped in a scikit-learn `Pipeline`.
> - All targets aggregated to **operating-point level** (board totals), NOT element level.
>
> **Fixed scope (state in all docs, never model):** everything is at one scan speed
> (~20 m/s — recovered `scan_speed_ms`, all rows), one water (20 °C seawater). Speed is
> NOT a feature: it never varies in the data. Same for water properties.
>
> ---
>
> ## 2. Data we already have
>
> - `SWD/data/operating_points.csv` — 720 rows, 29 boards, board-level force totals per
>   (board, drift, roll_case). This is the training-table prototype.
> - `SWD/data/boards.csv` — per-board geometry: `total_mass_kg`, `volume_shape_l`,
>   `volume_float_l`, `foam_mass_kg`.
> - `SWD/data/elements.csv` — per-element strips (do NOT train on these rows directly;
>   they are the spatial mesh of one solution, not independent samples).
> - Extraction tooling that already works: `SWD/tools/extract_board.ps1`,
>   `SWD/tools/census_board.ps1`. New `.fynrhydro` scan files are picked up automatically
>   but are **refused by the provenance gate until approved** (trust manifest).
>
> ---
>
> ## 3. Generating more boards — the geometry automation
>
> Goal: a large set of geometry variants of one parent board ("default_shortboard" or a
> copy of another scanned board), produced by driving SWD's Shape Room controls, then
> hydroscanned and extracted.
>
> **The three geometry controls and what they actually do (measured behaviour):**
>
> | Button | What it changes | Side effects |
> |---|---|---|
> | `Apply Length` | overall size, homothetic scaling (the "Preserve relative Rocker / Constant shape (homothety)" checkbox is permanently on/greyed) | **also changes Width and Volume** (uniform scale — volume grows ~cubically) |
> | `Apply Width` | width | **also changes Volume** |
> | `Apply Volume` | thickness only (rescales foil to hit target volume) | length and width unchanged |
>
> Consequence: these axes are NOT independent. Design the sweep accordingly:
> - Treat them as three sweep axes: **size** (length), **width**, **thickness** (volume).
> - One-factor-at-a-time ladders from the same parent, e.g. 5 volume steps at fixed
>   length/width, 5 width steps, 3 length steps. Small designed set first; scale up later.
> - **Never trust the nominal edit.** After every variant is saved and scanned, the
>   extracted geometry values are the ground truth features. Log intended vs extracted
>   for every variant and flag any drift in supposedly-fixed dimensions.
>
> **Automation route:** `SWD/tools/phase2/swd_msg.ps1` has already driven a full 11-angle
> hydroscan end to end against the real app (set numeric boxes, click buttons, handle
> dialogs). Reuse that layer. `control-map*.csv` files map the known controls.
>
> **Hard rules (from the project's own findings — violating these wastes hours):**
> 1. **Work only on save-as copies, never protected library originals.** SWD itself
>    diverts protected boards through a copy branch.
> 2. **The copy branch silently resets physics metadata** (measured: `turn_radius_m`
>    22.8 → 100000, `board_speed_setting_ms` changed). After creating any copy, verify
>    its stored fields before scanning; record them in the manifest.
> 3. **Do not try to change scan speed.** Measured result: the `flow ms` box does NOT
>    drive hydroscans (set to 10, scans still came back ≈20.04 m/s). All variants scan
>    at the default ~20 m/s, which is fine — geometry is the axis we are growing.
> 4. The static hydroscan requires **no wave loaded** (`<no Wave>` in the title bar).
>    Drift angle set is fixed (0,2,5,10,15,20,30,45,60,75,90 — 11 angles, ~61 s each,
>    ~12 min per board). Budget scan time accordingly.
> 5. Every new scan output goes through the **provenance gate / trust manifest** before
>    extraction. New files are untrusted until approved.
> 6. Run **one verification variant end to end first** (edit → save copy → scan →
>    extract → geometry values confirmed in CSV) before batching anything. Define the
>    acceptance criterion before running (e.g. "extracted volume within 2% of target,
>    forces present for 11/11 angles"). If it fails, stop and diagnose — do not batch.
> 7. Also worth scanning: the **13 genuinely distinct unscanned boards** already in the
>    library (~6 h total) — real geometry diversity, no editing needed. Skip
>    `default_shortboard_Copy_2` (geometric duplicate of Copy_3).
>
> ---
>
> ## 4. Validation requirements (non-negotiable)
>
> - **Split by board, never by row.** All operating points of one board (and all its
>   near-identical sweep siblings — see next point) stay together in train or test.
> - **Sweep variants of one parent are a family.** For the generalization claim, hold
>   out whole families or the 29 original diverse boards. A variant in train and its
>   sibling in test inflates scores and proves nothing. Two separate questions, two
>   separate splits: (a) within-family: how does force respond to volume/width/size;
>   (b) across-board: does the model transfer to unseen shapes.
> - Withhold ≥20% as an untouched test set (project rubric requirement). Use
>   **leave-one-board-out cross-validation** for model selection; report the spread of
>   scores, not just the mean.
> - Metrics: MAE, RMSE, R² per target; report **relative** errors too (rail forces are
>   small — raw newtons flatter the wrong models).
> - **Envelope check in the predict API:** refuse or warn when a query's features fall
>   outside the training ranges (the spec requires explicit out-of-bounds handling).
>
> ## 5. Baselines and consistency checks (this is where the marks are)
>
> 1. **Condition-only baseline:** same model, drift+roll features only, no geometry.
>    The improvement geometry features add, on held-out boards, is the measured value of
>    the geometry axis. If it's ~zero, that is a reportable finding, not a failure.
> 2. **Physics baseline for friction:** the recovered friction correlation
>    (reimplemented in the repo, reproduces SWD to a few %). The ML friction model must
>    be compared against it.
> 3. **Consistency audit:** predict total drag directly AND as the sum of the component
>    models; compare both to SWD truth on held-out boards. Divergence localizes the weak
>    component model.
>
> ## 6. Engineering standards (unit requirements)
>
> pytest tests on analytical cases; NumPy-style docstrings on every function; pdoc HTML
> docs; meaningful git commits with branching; README with reproduction commands;
> `/data`, `/src`, `/tests`, `/docs` layout. Log every scan (variant name, intended
> edit, extracted geometry, timestamps) in a manifest CSV so provenance can be recited.
>
> ## 7. Order of work
>
> 1. Read `CLAUDE.md`, `SWD/docs/what-swd-can-yield.md`, `SWD/docs/phase2-hydroscan.md`,
>    `SWD/tools/phase2/LIVE-RUN-FINDINGS.md` before touching anything.
> 2. Build + validate the model pipeline on the EXISTING 720 operating points first
>    (models, splits, baselines, metrics). This works today with zero new scans.
> 3. One verification geometry variant end to end (§3 rule 6).
> 4. Scan the 13 unscanned library boards.
> 5. Batch the designed geometry sweep, extract, retrain, compare against step 2.

### 2026-09-01 12:17 · `50a19d62` · `main`

> This should be the main idea for the project, it has been worked on to ensure that the goals are possible.

### 2026-09-01 12:17 · `50a19d62` · `main`

> Make sure the processes are extract only, no more computed data should be made

### 2026-09-01 12:18 · `50a19d62` · `main`

> This process would require you to hydroscan the remaining 14

### 2026-09-01 12:19 · `50a19d62` · `main`

> Sparingly scrap the older plans

### 2026-09-01 12:21 · `50a19d62` · `main`

> Also part of this process should be integrating use of the discussed (in the plan i gave) added data points, through editing flow speed, etc. to each board.

### 2026-09-01 12:21 · `50a19d62` · `main`

> If you do this after completing a hydroscan, that would add significant amount of data points with less required time

### 2026-09-01 12:22 · `50a19d62` · `main`

> AHhh yes apologies you are correct

### 2026-09-01 12:22 · `50a19d62` · `main`

> Flow ms is dead for now, and not important in this

### 2026-09-01 12:23 · `50a19d62` · `main`

> I mean tto say you could involve a change to the dimensions of the board each time you conduct a hydroscan to that board.

### 2026-09-01 12:23 · `50a19d62` · `main`

> Maybe in 1% increments each way (+-20%) to gain as many data points as possible for each board

### 2026-09-01 12:24 · `50a19d62` · `main`

> Think about what would need to be created for this

### 2026-09-01 12:26 · `50a19d62` · `main`

> Capturing it with 5 points rather than 41 would be very beneficial

### 2026-09-01 12:26 · `50a19d62` · `main`

> That sounds better, mine was just an idea

### 2026-09-01 12:38 · `50a19d62` · `main`

> Can you edit the plan, such that you produce a way for SWD to switch boards on its own? This is necessary in the headless aspect of it, run SQA before using

### 2026-09-01 13:12 · `50a19d62` · `main`

> keep going with physics_baseline and predict

### 2026-09-01 13:14 · `50a19d62` · `main`

> Then write the .ps1 files you described, then run SQA on them, make a todolist to remember each step

### 2026-09-01 23:31 · `50a19d62` · `main`

> So give me a brief rundown of what you got done from the todolist

### 2026-09-01 23:33 · `50a19d62` · `main`

> Can we carry out 2b.5 and 2b.6?

### 2026-09-02 00:03 · `abc4f67c` · `furtherSWDextract`

> Can you add to the gitignore, any files that were computed

### 2026-09-02 00:09 · `abc4f67c` · `furtherSWDextract`

> Could you also have a look at the project brief, as well as the AI documentation rules, and include in the claude md of this file, any requirements they include for the documentation around AI use. For example whether every prompt needs to be recorded, then if that were a requirement you would start noting down every prompt into a document. Also anything you find, make it a rule in CLAUDE.md for this project

### 2026-09-02 00:09 · `abc4f67c` · `furtherSWDextract`

> Rules for mma3001 that is

### 2026-09-02 00:14 · `abc4f67c` · `furtherSWDextract`

> Also explain all this in the README

### 2026-09-02 00:14 · `abc4f67c` · `furtherSWDextract`

> Is it possible for you to extract past prompts too?

### 2026-09-02 00:15 · `abc4f67c` · `furtherSWDextract`

> Link the github repo: https://github.com/bennmoors/SQA-loop, to explain the basic process of how agentic ai has been used for code verification

### 2026-09-02 00:54 · `50a19d62` · `furtherSWDextract`

> I did not mean to stop it, continue it.

### 2026-09-02 00:54 · `50a19d62` · `furtherSWDextract`

> When it is done, do not automaticall yrun code-reviewer, I will run that later

### 2026-09-02 00:56 · `50a19d62` · `furtherSWDextract`

> Actually cancel this new one

### 2026-09-02 05:01 · `50a19d62` · `furtherSWDextract`

> continue SQA loop

### 2026-09-02 05:01 · `50a19d62` · `furtherSWDextract`

> No do the full loop,

### 2026-09-02 05:01 · `50a19d62` · `furtherSWDextract`

> With the fixer

### 2026-09-02 05:01 · `50a19d62` · `furtherSWDextract`

> Until loop is finished as in global CLAUDE.md

### 2026-09-02 10:22 · `50a19d62` · `furtherSWDextract`

> Continue

### 2026-09-02 10:48 · `50a19d62` · `furtherSWDextract`

> So the session would have rest by now?

### 2026-09-02 11:31 · `50a19d62` · `furtherSWDextract`

> A fourth fix round, then what would be next?

### 2026-09-02 11:56 · `50a19d62` · `furtherSWDextract`

> I have opened SWD, and expanded the folders

### 2026-09-02 11:59 · `50a19d62` · `furtherSWDextract`

> Finished, response was:verify_2b.ps1  -  live verification of TODO 2b.5 / 2b.6
> started        : 2026-09-02T21:58:21.6511962+10:00
> host           : 5.1.26100.9168 Desktop
> log            : ~\HYDRODYNAMICS-FIN\SWD\tools\phase2\logs\20260902-215821-644-2b-verify.log
> mode           : full - sections E and F select boards
>
> ========================================================================
> A. Preflight - process identity, integrity, resident board
> ========================================================================
> pid            : 30668
> started        : 2026-09-02T21:52:34.9208054+10:00
> integrity us   : S-1-16-12288
> integrity SWD  : S-1-16-12288
> caption        : FYN Shaper Wave Dynamics   <Board: default_shortboard_Copy_1(1830mm)> <no Wave> <Surfer: Surfer Pro(80Kg)>
> resident board : default_shortboard_Copy_1  (1830 mm)
> top-level      : 1 visible window(s) - WindowsForms10.Window.8.app.0.141b42a_r7<CUT>
> dialogs open   : none
> library        : ~\\OneDrive - Monash University\\Documents\\ShaperWaveDynamics documents\\biblio\\Boards  (from Documents)
> hashed         : 29 .fynbs (baseline AFTER launch, BEFORE any selection)
>
> ========================================================================
> B. Tree census - every TreeItem UIA can see, diffed against boards.csv
> ========================================================================
> tree items     : 0  (0 selectable, 0 not)
> boards.csv     : 29 canonical names
> missing        : 2003_Taylor_Knox_channel_island_Copy_1 | Bruce Iron Brewer Gun_Copy_1 | default_shortboard_Copy_1 | default_shortboard_Copy_2 | default_shortboard_Copy_3 | default_shortboard_Copy_4 | Poahaku | 7_6_Dynamics_bear | EggArmy | Jules_egg | blueTreck | default_evolutive | DanielThomson_ModernPlaningHull | default_fish | Steve LIS Gun fish with sides bites | Steve Lis Transition Era Fish | Bruce Iron Brewer Gun | default_longboard | default_paddle | 2003_Taylor_Knox_channel_island | Bells Thruster 1981 | cole quad dynamics | default_shortboard | McTavish Ricon Tracker 1968 | Bettsy_TowIn | HydroActiveFyn | Laser_Zap_Ben_Aipa | Mini_Simmons | hydroactive_Wake
> extra in tree  : none
> HALT           : 29 canonical board(s) are not selectable in the tree. A folder was almost certainly left collapsed - Select-SwdBoard never expands, so a board under a closed folder is absent from the UIA tree entirely. Expand all 11 folders and re-run.
>
> ========================================================================
> C. Menu census - 2b.6, read-only. NOTHING IS INVOKED.
> ========================================================================
> skipped        : the run halted before this section; see HALT in the summary.
>
> ========================================================================
> D. Rehearsal - Select-SwdBoard -WhatIf over every canonical board
> ========================================================================
> skipped        : the run halted before this section; see HALT in the summary.
>
> ========================================================================
> E/F. Skipped - the run halted before any board was selected.
> ========================================================================
>
> ========================================================================
> G. Did any of that write to the library?
> ========================================================================
> files before   : 29
> files after    : 29
> changed        : none
> added          : none
> removed        : none
> unreadable     : none
>
> ========================================================================
> SUMMARY
> ========================================================================
>   A  ok
>   B  HALT - census short of canonical list
>   C  skipped - halted earlier
>   D  skipped - halted earlier
>   E  skipped - halted earlier
>   F  skipped - halted earlier
>   G  no library file changed during this run
>
> HALTED: 29 canonical board(s) are not selectable in the tree. A folder was almost certainly left collapsed - Select-SwdBoard never expands, so a board under a closed folder is absent from the UIA tree entirely. Expand all 11 folders and re-run.
>
> What this run does NOT establish, whatever it printed:
>   - nothing about the three Apply buttons; Set-SwdGeometry was never called
>   - nothing about saving; Invoke-SwdMenuItem was never called, so 2b.6 rests on
>     the pattern being ADVERTISED, not on Invoke() having been fired
>   - nothing about scanning; no .fynrhydro was written or read
>   - section G is one observation over one short run, and does not generalise
>     to a 12-minute scan, which is separately on record as writing to the library
>
> artefacts written:
>   ~\HYDRODYNAMICS-FIN\SWD\tools\phase2\logs\20260902-215821-644-2b-verify.log
>   ~\HYDRODYNAMICS-FIN\SWD\tools\phase2\logs\20260902-215821-644-2b-boards.csv
>   ~\HYDRODYNAMICS-FIN\SWD\tools\phase2\logs\20260902-215821-644-2b-menu.csv
>   ~\HYDRODYNAMICS-FIN\SWD\tools\phase2\logs\20260902-215821-644-2b-hashes.csv
> finished       : 2026-09-02T21:58:22.3870788+10:00

### 2026-09-02 12:02 · `50a19d62` · `furtherSWDextract`

> I have unminimised it

### 2026-09-02 12:06 · `50a19d62` · `furtherSWDextract`

> Ran it: powershell.exe -NoProfile -ExecutionPolicy Bypass -File "~\HYDRODYNAMICS-FIN\SWD\tools\phase2\verify_2b.ps1"
> verify_2b.ps1  -  live verification of TODO 2b.5 / 2b.6
> started        : 2026-09-02T22:05:30.5865224+10:00
> host           : 5.1.26100.9168 Desktop
> log            : ~\HYDRODYNAMICS-FIN\SWD\tools\phase2\logs\20260902-220530-580-2b-verify.log
> mode           : full - sections E and F select boards
>
> ========================================================================
> A. Preflight - process identity, integrity, resident board
> ========================================================================
> pid            : 30668
> started        : 2026-09-02T21:52:34.9208054+10:00
> integrity us   : S-1-16-12288
> integrity SWD  : S-1-16-12288
> caption        : FYN Shaper Wave Dynamics   <Board: default_shortboard_Copy_1(1830mm)> <no Wave> <Surfer: Surfer Pro(80Kg)>
> resident board : default_shortboard_Copy_1  (1830 mm)
> top-level      : 1 visible window(s) - WindowsForms10.Window.8.app.0.141b42a_r7<CUT>
> dialogs open   : none
> library        : ~\\OneDrive - Monash University\\Documents\\ShaperWaveDynamics documents\\biblio\\Boards  (from Documents)
> hashed         : 29 .fynbs (baseline AFTER launch, BEFORE any selection)
>
> ========================================================================
> B. Tree census - every TreeItem UIA can see, diffed against boards.csv
> ========================================================================
> tree items     : 0  (0 selectable, 0 not)
> boards.csv     : 29 canonical names
> missing        : 2003_Taylor_Knox_channel_island_Copy_1 | Bruce Iron Brewer Gun_Copy_1 | default_shortboard_Copy_1 | default_shortboard_Copy_2 | default_shortboard_Copy_3 | default_shortboard_Copy_4 | Poahaku | 7_6_Dynamics_bear | EggArmy | Jules_egg | blueTreck | default_evolutive | DanielThomson_ModernPlaningHull | default_fish | Steve LIS Gun fish with sides bites | Steve Lis Transition Era Fish | Bruce Iron Brewer Gun | default_longboard | default_paddle | 2003_Taylor_Knox_channel_island | Bells Thruster 1981 | cole quad dynamics | default_shortboard | McTavish Ricon Tracker 1968 | Bettsy_TowIn | HydroActiveFyn | Laser_Zap_Ben_Aipa | Mini_Simmons | hydroactive_Wake
> extra in tree  : none
> HALT           : 29 canonical board(s) are not selectable in the tree. A folder was almost certainly left collapsed - Select-SwdBoard never expands, so a board under a closed folder is absent from the UIA tree entirely. Expand all 11 folders and re-run.
>
> ========================================================================
> C. Menu census - 2b.6, read-only. NOTHING IS INVOKED.
> ========================================================================
> skipped        : the run halted before this section; see HALT in the summary.
>
> ========================================================================
> D. Rehearsal - Select-SwdBoard -WhatIf over every canonical board
> ========================================================================
> skipped        : the run halted before this section; see HALT in the summary.
>
> ========================================================================
> E/F. Skipped - the run halted before any board was selected.
> ========================================================================
>
> ========================================================================
> G. Did any of that write to the library?
> ========================================================================
> files before   : 29
> files after    : 29
> changed        : none
> added          : none
> removed        : none
> unreadable     : none
>
> ========================================================================
> SUMMARY
> ========================================================================
>   A  ok
>   B  HALT - census short of canonical list
>   C  skipped - halted earlier
>   D  skipped - halted earlier
>   E  skipped - halted earlier
>   F  skipped - halted earlier
>   G  no library file changed during this run
>
> HALTED: 29 canonical board(s) are not selectable in the tree. A folder was almost certainly left collapsed - Select-SwdBoard never expands, so a board under a closed folder is absent from the UIA tree entirely. Expand all 11 folders and re-run.
>
> What this run does NOT establish, whatever it printed:
>   - nothing about the three Apply buttons; Set-SwdGeometry was never called
>   - nothing about saving; Invoke-SwdMenuItem was never called, so 2b.6 rests on
>     the pattern being ADVERTISED, not on Invoke() having been fired
>   - nothing about scanning; no .fynrhydro was written or read
>   - section G is one observation over one short run, and does not generalise
>     to a 12-minute scan, which is separately on record as writing to the library
>
> artefacts written:
>   ~\HYDRODYNAMICS-FIN\SWD\tools\phase2\logs\20260902-220530-580-2b-verify.log
>   ~\HYDRODYNAMICS-FIN\SWD\tools\phase2\logs\20260902-220530-580-2b-boards.csv
>   ~\HYDRODYNAMICS-FIN\SWD\tools\phase2\logs\20260902-220530-580-2b-menu.csv
>   ~\HYDRODYNAMICS-FIN\SWD\tools\phase2\logs\20260902-220530-580-2b-hashes.csv
> finished       : 2026-09-02T22:05:31.5955968+10:00

### 2026-09-02 12:08 · `50a19d62` · `furtherSWDextract`

> integrity us  :
> visual state  : Maximized
>
> descendants   : 134
>     78  Pane
>     16  Text
>     15  Button
>      9  MenuItem
>      6  Group
>      3  Separator
>      2  ComboBox
>      2  MenuBar
>      1  Thumb
>      1  ToolBar
>      1  StatusBar
>
> === 2b.6 : every MenuItem, its state, and whether Invoke is exposed ===
> MenuItem count: 9
>   name='Reset' enabled=True invokable=True expandable=False
>   name='Fin Show' enabled=True invokable=True expandable=True
>   name='Files' enabled=True invokable=True expandable=True
>   name='Tools' enabled=True invokable=True expandable=True
>   name='Interface color' enabled=True invokable=True expandable=True
>   name='User Settings' enabled=True invokable=True expandable=False
>   name='Shaper report 0 pages' enabled=True invokable=True expandable=False
>   name='Tutorials' enabled=True invokable=True expandable=True
>   name='Available update: Version1.1.0.6 of 27/02/2026' enabled=True invokable=True expandable=True
>
> === 2b.5 : is the library tree a Tree at all? ===
>   Tree      : 0
>   TreeItem  : 0
>   List      : 0
>   ListItem  : 0
>
>   elements whose class is a SysTreeView32, and what they expose:
>     type=Pane name='' children=0 SelectionPattern=False

### 2026-09-14 07:07 · `daa5cecd` · `furtherSWDextract`

> I have just downloaded Obsidian CLI, and want to integrate it into this project, to ensure efficiency, and memory of the project. Do some deep research of the obsidian cli, repos integrating its use, how other people have used it, and its biggest gains overall. Figure out some directions that I could integrate it into my claude code directory for gains in efficiency (token and time) and overall effectiveness of output. Keep in mind this is a github repository too, so anyway I could make the whole thing accessible to my friend too to use would be beneficial. I have one vault, which is currently 1GB size, can upgrade if necessary, but would prefer to save money.

### 2026-09-14 07:08 · `daa5cecd` · `furtherSWDextract`

> I also gave this prompt to gemini and fable and they came back with FABLE-RES and GEM-RES files

### 2026-09-14 07:08 · `daa5cecd` · `furtherSWDextract`

> I have a vault integrated into this project

### 2026-09-14 07:12 · `daa5cecd` · `furtherSWDextract`

> Make it so in future all projects use obisidan integration, but as efficiencytly as possible, just for memory.

### 2026-09-14 07:12 · `daa5cecd` · `furtherSWDextract`

> Replace graphify with this

### 2026-09-14 07:23 · `daa5cecd` · `furtherSWDextract`

> Have a lookat mcp-obsidian too

### 2026-09-14 07:25 · `daa5cecd` · `furtherSWDextract`

> If it would not was too many tokens, also have a look at using it for a whole project, then give me pros and cons in the question form

<!-- prompts:end -->
