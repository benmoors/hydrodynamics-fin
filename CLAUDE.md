# HYDRODYNAMICS-FIN — project instructions

Read this before doing anything in this repository.

## 1. What this project is

MMA3001 (Numerical Methods and Machine Learning) **individual project — 25% of the unit mark**.

The project is a **"Virtual Surfer" performance simulator**: an ML surrogate trained on hydrodynamic
grids from ShaperWaveDynamics (SWD), queried at 100 Hz along a synthetic on-wave trajectory, feeding
two performance indicators — **Board-Jerk (BJ)** and **Radicality (Ra)**.

Downstream, the modelling informs firmware for a surfboard-fin sensor PCB (ICM-20948 IMU +
MS5837-30BA + STM32). See [fin_sensor_pcb_overview.md](fin_sensor_pcb_overview.md). That is **later work** — the current focus is
the machine learning.

**Knowledge base:** the Obsidian wiki in `wiki/` is built for this project. Unit, brief/rubric, paper
and data questions go through it first; see "Second brain" at the end of this file.

### Scope boundary — this matters

`SWD/` is **data acquisition only**: getting SWD's hydrodynamic output into CSV/arrays.

The surrogate model, Board-Jerk, Radicality, trajectory integration and the written report are the
**student's own work**. Do not write them unless explicitly asked. If asked to "continue the
project", confirm which part rather than assuming the ML is wanted.

## 2. Assessment requirements

Every deliverable is judged against these. Source: `Project/MMA3001_2026_Project_Brief.pdf` (15 pages;
requirements pp. 4–7, deliverables pp. 8–9, rubric pp. 10–15). **`mma3001-project-spec.md` is NOT a
source** — it is an AI-compiled context sheet (its own line 3 says so) and it invents specifics the
brief does not contain. Verified against the PDF text 2026-09-02.

Documentation acts as the project report and must cover: engineering problem, inputs and outputs,
computational solution, alternative solutions, validation, optimisation and performance, AI use.

The rubric (pp. 10–15) has **six criteria, one per page, and NO weights** — the only number is the
project's **25% of the unit mark** (p. 1). Each is marked Excellent / Good / Satisfactory / Poor:

1. Engineering problem, inputs and outputs (p. 10)
2. GitHub repository structure, commits and ReadME (p. 11)
3. Inline comments, docstrings, and HTML documentation (p. 12)
4. Validation and engineering credibility (p. 13)
5. Justification of Computational Approach (p. 14)
6. AI use and critical reflection (p. 15)

> An earlier version of this section carried a seven-row table weighted 10/10/10/20/25/15/10 and
> cited the brief for it. That table came from `mma3001-project-spec.md`, not the PDF. Recorded in
> `AI-USE.md` § 5 as an AI error.

Non-negotiables that are easy to miss:

- **At least one credible baseline or alternative** must be implemented and compared with evidence
  (p. 5: "selected using evidence rather than preference alone"). A single solution with no
  comparison fails criterion 5 outright.
- **Withheld test data is one of ten accepted validation routes (p. 5), not a mandated split.** The
  "≥ 20% with RMSE / MAE / R²" that used to stand here is from the spec sheet — neither figure appears
  in the brief. Keep the grouped hold-out and the three metrics as this project's *chosen* method, and
  justify it as such; do not present it as a requirement.
- **State what the validation cannot establish.** The brief asks for this explicitly, and the marker
  looks for it. "A numerical result or visually convincing output is not sufficient evidence."
- Inputs and outputs need **data types, physical units, operating ranges and mathematical domains**,
  plus how invalid, missing or out-of-bounds values are handled.
- Automated tests (`pytest`) against **analytical cases with known exact solutions**.
- NumPy-style docstrings; HTML docs via `pdoc`.
- Report failures honestly. Per the brief, a partially successful method still earns a strong result
  if validated honestly with limitations identified. **Never dress up a negative result.**

## 3. AI documentation rules

Two sources, both read in full and verified against the originals on 2026-09-02:
`Project/MMA3001_2026_Project_Brief.pdf` (§ 7 on p. 6, deliverables pp. 8–9, rubric p. 15) and
`Project/MMA3001-Notes-Week01.4-Responsible-Use-of-AI.ipynb`. The brief is binding; the notebook is
what the unit teaches and models. The record that satisfies both is **`AI-USE.md`** at the repo root.

### 3.1–3.2 What the brief and the notebook require

Moved verbatim to `.claude/rules/ai-use-requirements.md`, which
loads when `AI-USE.md`, `README.md` or `tools/extract_prompts.py` is read. **Read it before writing
any AI acknowledgement, reflection or `AI-USE.md` entry** — it holds the brief's eight required
points, where they must appear, and the rubric row.

### 3.3 Rules for this repository

| # | Rule |
|---|---|
| **R1** | **`AI-USE.md` is the single AI-use record.** Sections: tools (name, version, model, access-date range, what it did); task log; approximate contribution; decisions that remained mine; errors ledger; prompt appendix. **Append-only** — an entry is corrected by a later entry, never edited away. |
| **R2** | **Log a task entry whenever AI output ships into the repo or changes a design decision**: date, tool + version + model, the prompt verbatim, what was changed about the output, how it was verified. Tool calls, file reads and chat that produced nothing are not logged. |
| **R3** | **Every correction, withdrawal or refuted premise gets an errors-ledger entry** — date, what was believed, what was true, how it was caught, who caught it — **in the same change that lands the correction.** Never delete one. The strikethrough convention (`~~…~~`) stays in the source documents; the ledger is the index. |
| **R4** | **The prompt appendix is generated, never typed:** `python tools/extract_prompts.py`. It reads all three CLIs, each labelled with its version and model: Claude Code (`~/.claude/projects/`), agy (`~/.gemini/antigravity-cli/`) and Devin (`%APPDATA%\Devin\cli\transcripts\`). A session opened above the repo (e.g. `UNIVERSITY/`) contributes only the turns whose prompt or tool calls named HYDRODYNAMICS-FIN. All three stores are pruned, so extract early and re-run before every submission. A re-run never loses a committed prompt: sessions no longer on disk are carried forward from the existing appendix, and the script refuses to shrink it without `--allow-shrink` (E81). Sessions that only brushed the repo are listed in `_EXCLUDED` with a reason. Claude Code keeps transcripts 365 days (`cleanupPeriodDays`). Times render in Melbourne local time, labelled AEST/AEDT; entries in §§ 1–5 written before 2026-09-29 cite UTC. The script redacts the home directory and flags licence/registry patterns. **Since 2026-09-29 a `SessionEnd` hook (`tools/prompt_appendix_hook.py`) regenerates and commits § 6 with no human read before the commit** (the author's decision, § 4). It holds on a new prompt matching a licence, registry, home or tenant pattern, and on uncommitted `AI-USE.md` edits. The `SessionStart` hook prints any hold. It never pushes, so **a human reviews § 6 before every push**. |
| **R5** | **The README `## 🤖 AI Acknowledgment` and the report's reflection are written from `AI-USE.md`, never from memory.** All eight brief bullets must be answerable from the log. |
| **R6** | **State the approximate AI contribution per component**, as a rough share plus who made the decision (`AI-USE.md` § 3). The brief asks for "approximate"; a number, however rough, beats prose. |
| **R7** | **Interview rule: nothing in the repo the student cannot explain unaided.** AI-written code or analysis the student cannot explain is learned or removed before submission (p. 6 bans AI in the interview; p. 8 says the mark rests on answering questions). Every module gets an explicit "can I explain this" pass, recorded in `AI-USE.md` § 4. |
| **R8** | **Never cite an AI as a source.** The student is responsible for **references** (p. 6): every citation is checked to exist — DOI resolves, page opened — before it is used. |
| **R9** | **Data security.** The licence key, `.reg` backups, registry values, SWD binaries, shaper names and library paths (username, tenant) are never pasted into any AI tool and never appear in a committed artefact. Claude Code sends file contents to Anthropic's API, so for the licence and the `.reg` backup the boundary is *never read by Claude*, not merely never committed. |
| **R10** | **Never style-edit `AI-USE.md`, the README `## 🤖 AI Acknowledgment`, or the report's reflection** — humanizer or otherwise, even when a prose pass is applied to the rest of the document. They are graded, and the student is personally accountable for every claim. |
| **R11** | No `Co-Authored-By` trailers or "Generated with Claude Code" lines on commits or PRs. The disclosure lives in `AI-USE.md`, where it is complete rather than a badge. |
| **R12** | **The student drives.** AI proposes; the student decides. Each design decision (method choice, feature set, split strategy, what to exclude, what to report as a failure) is recorded under "decisions that remained mine" in `AI-USE.md` § 4. |

## 4. SWD safety rules

The SWD licence cost **EUR 210** and is machine-bound to one registry value,
`HKLM\SOFTWARE\WOW6432Node\swdy\info`. Protecting the installation outranks convenience.

- **Never write inside `C:\Program Files\ShaperWaveDynamics\`.** Read-only, always. The app writes its
  own `log_start.txt` there; leave it alone.
- **Never modify a file in the SWD library in place** (`...\Documents\ShaperWaveDynamics documents\biblio\`).
  To change a board, deserialise a **copy**, edit it, and write to a scratch folder.
- **Never construct `Form_shaper` headlessly.** It pulls in SlimDX/DX11 device creation and a bundled
  `WinSCP.exe`. Report generation genuinely requires it, so scans go through the real GUI instead.
- Verify backups exist before any operation that touches the app. Backups live at
  `%USERPROFILE%\SWD-backup\<date>\` — **outside this repo**, because the `.reg` file contains the
  licence key and the library is 627 MB.
- **Never commit the licence key.** `.gitignore` blocks `*.reg` and `SWD/backup/`; do not weaken it.
- Run an SQA pass over any new `.ps1` that touches SWD before running it against the real installation.
- **The extractor has a provenance gate: nothing is deserialised unless its SHA-256 is in the trust
  manifest** (`%LOCALAPPDATA%\swd-extract\trusted_files.json`, deliberately outside the repo).
  `BinaryFormatter.Deserialize` on an untrusted stream is arbitrary code execution, and the library is
  cloud-synced with files from seven authors, so "they are your own files" does not hold. After any
  hydroscan session, re-approve with `-TrustCurrentLibrary`. **Never reach for `-AllowUntrustedFiles`
  to avoid that friction** — it disables the gate for the whole run. Full rationale and limits in
  [SWD/docs/provenance-gate.md](SWD/docs/provenance-gate.md); it is trust-on-first-use and does NOT make `BinaryFormatter` safe.

## 5. Technical facts already established — do not rediscover these

Moved verbatim to `.claude/rules/swd-technical-facts.md`, which
loads when any file under `SWD/`, `src/` or `tests/` is read: `BinaryFormatter`/PowerShell 5.1,
`AssemblyResolve` recursion, `[NonSerialized]` fake zeros, French accents and locale, BOM-less CSV,
the 4-entry density table, the one-speed-two-temperatures finding, and the Blasius friction model.
**Read it before any SWD extraction work or any physics claim about density, speed or drag.**

## 6. Data integrity rules

- **`elements.csv` rows are not independent samples.** They are the spatial mesh along one board at
  one condition. Training on them is pseudo-replication: near-duplicate rows straddle any random
  split and inflate R-squared. Use `operating_points.csv` (**720 rows**, 29 boards) as the training table.
- **Group any train/test split by board.** Rows from one board share speed and radius exactly.
- **`scan_speed_ms` is the physical condition; `board_speed_setting_ms` is metadata and is NOT the
  speed the scan ran at.** All **154** existing reports were computed at 20.000 m/s while the stored
  setting varies over 2-20 m/s. Using the stored setting as a feature trains on a label that does not
  describe the physics.
- **Never fabricate a `.fynrhydro`.** Inputs (`.fynbs`) may be synthesised from copies; outputs are
  physics and must come from SWD. Fabricating them is both useless for training and an integrity
  breach.
- Report dataset limitations plainly. The existing corpus has **one** scan speed, so any claim about
  generalisation across speed is unsupported until Phase 2 scans exist.

## 7. Repository layout

    HYDRODYNAMICS-FIN/              also the Obsidian vault root
    |- CLAUDE.md                    this file
    |- GEMINI.md                    Antigravity / Gemini CLI root config & SQA protocol
    |- AI-USE.md                    the AI-use record -- section 3
    |- memory/                      Claude Code auto memory, committed and shared
    |- .claude/
    |   |- rules/                   path-scoped rules moved out of this file (sections 3.1-3.2, 5)
    |   |- skills/obsidian-memory/  link-graph work through the Obsidian CLI and MCP
    |   \- settings.json            permission denies for the Obsidian MCP server
    |- .mcp.json                    Local REST API MCP server (key from OBSIDIAN_API_KEY)
    |- .obsidian/                   shared vault config (workspace and plugin data.json ignored)
    |- tools/extract_prompts.py     regenerates AI-USE.md's prompt appendix
    |- Project/                     unit materials (gitignored); Week NN/ = unit notebooks
    |- wiki/                        MMA3001 project second brain (gitignored) -- CLAUDE.md query card,
    |                               SCHEMA.md full schema, rubric.base; searched by qmd (local MCP)
    |- SWD/                         data acquisition
    |   |- TODO.md                  live progress checklist
    |   |- tools/swd_extract.ps1    SWD binary -> CSV
    |   |- data/                    extracted CSVs
    |   \- docs/
    |       |- plans/              stage plans -- see section 9
    |       \- worklist/           one note per worklist item + worklist.base
    |- fin_sensor_pcb_overview.md   downstream hardware
    |- surfing-performance-io.md    BJ / Ra specifications
    \- mma3001-project-spec.md      project + syllabus reference

**Known defect in the supplied specs:** `surfing-performance-io.md` and `mma3001-project-spec.md`
disagree on the trajectory length `D` in the Board-Jerk normalisation. The paper (Charles et al. 2026,
*Results in Engineering* 29:108868, DOI 10.1016/j.rineng.2025.108868) **Eq 7** defines `D` as the
double integral of acceleration — net displacement. `mma3001-project-spec.md` Part 4 section 2 uses
the arc length (integral of V(t) dt), a different quantity, and it enters `J` squared through
`C = T^5/D^2`. **Follow the paper** (`1-s2.0-S2590123025049114-main.pdf`, in the repo). Confirmed
correct in both docs: Eq 4, 5, 6, 10, and Eq 11 (`Ra = theta_z^2 / (t1 - t0)`).

## 8. Working style

- Keep [SWD/TODO.md](SWD/TODO.md) and the worklist notes' `status` current — the work spans sessions
  and days of scan time.
- When a correction lands anywhere, add it to the `AI-USE.md` errors ledger in the same change
  (section 3, R3). A correction that is not in the ledger is one the marker cannot see.
- Prefer the simplest thing that works; this is coursework, not production infrastructure.
- Match the Week-01 notebook house style in human-read documents: a title with the blue-book emoji, a
  Learning Objectives block, numbered sections each followed by a horizontal rule, sub-topics, "Point
  of note" and "Aside" blockquotes, and results as tables.
- State uncertainty plainly. An honest "not measured" beats a confident guess, and the rubric rewards
  it.

---

## 9. Work index — what is next

**This section is the single answer to "what is the next thing to be done".** Stage plans live in
`SWD/docs/plans/`. Each is standalone: read the whole file before acting.

### Ordered worklist

One note per item in [SWD/docs/worklist/](SWD/docs/worklist/worklist.base), each with `order`,
`status` (`done|failed|blocked|candidate|todo`), `effort`, `blocked_by` and `plan` frontmatter, and
the item's full narrative in the body.

- **Status, app open:** `obsidian base:query path=SWD/docs/worklist/worklist.base format=json`
- **Status, app closed:** Grep `^status:` in `SWD/docs/worklist/`
- **⚠️ Item 2 FAILED its gate** — read [02](SWD/docs/worklist/02-wp3-steps-0-3-verification-scan.md)
  before touching WP3. Item [01](SWD/docs/worklist/01-wp1-supplementary-data.md) holds the four
  corrections WP2 must not re-derive.

**Keep the status column current.** A stale index is worse than none.

### Phrase routing

| When I say | Read |
|---|---|
| "begin Step 0", "Steps 0-3", "the verification scan" | [SWD/docs/plans/WP3-STEP-0-3-verification-scan.md](SWD/docs/plans/WP3-STEP-0-3-verification-scan.md) |
| "begin Step 4", "the batch driver", "write swd_scan" | [SWD/docs/plans/WP3-STEP-4-batch-driver.md](SWD/docs/plans/WP3-STEP-4-batch-driver.md) |
| "begin Step 5", "Step 6", "Step 7", "run the batch" | [SWD/docs/plans/WP3-STEP-5-7-batch-run.md](SWD/docs/plans/WP3-STEP-5-7-batch-run.md) |
| "WP1", "WP2", "the supplementary data", "the metrics document" | [SWD/docs/plans/WP1-WP2-paper-data-and-metrics.md](SWD/docs/plans/WP1-WP2-paper-data-and-metrics.md) |
| "the equations", "the paper's metrics", "Board-Jerk", "Radicality", "what should this number be", "the validation targets" | `wiki-query`, or wiki pages *Board-Jerk*, *Radicality Indicator*, *Project Validation Evidence and Limits*; the audit detail is in [SWD/docs/performance-metrics.md](SWD/docs/performance-metrics.md) |
| "what can SWD give us", "what data can be extracted", "why is the speed stuck at 20" | `wiki-query`, or wiki *ShaperWaveDynamics*; the full account is in [SWD/docs/what-swd-can-yield.md](SWD/docs/what-swd-can-yield.md) |
| "what inputs can I use", "what features", "how does this map to the paper's equations", "the IMU channels" | `wiki-query`, or wiki *SWD Operating Points Dataset*; the full catalogue is in [SWD/docs/project-io-spec.md](SWD/docs/project-io-spec.md) |
| "what went wrong in the live run", "the SQA findings from the scan" | [SWD/tools/phase2/LIVE-RUN-FINDINGS.md](SWD/tools/phase2/LIVE-RUN-FINDINGS.md) |
| "the scan dialogs", "what dialogs does the scanner raise" | [SWD/tools/phase2/SCAN-FLOW.md](SWD/tools/phase2/SCAN-FLOW.md) |
| "the probes", "fiddling", "the side-effect rig", "the evening run" | [SWD/docs/plans/SWD-AUTOMATION-PROBES.md](SWD/docs/plans/SWD-AUTOMATION-PROBES.md); evidence in wiki *SWD Automation Technique Register* |
| "the AI acknowledgement", "AI use", "the prompt log", "what did the AI get wrong" | [AI-USE.md](AI-USE.md), rules in section 3 and `.claude/rules/ai-use-requirements.md` |
| "what is next", "what should I do now" | this section, then the [worklist notes](SWD/docs/worklist/worklist.base) |
| "the memory", "what do you remember", "tidy the notes", "broken links" | [memory/MEMORY.md](memory/MEMORY.md) and `/obsidian-memory` |
| "the wiki", "second brain", "what does my wiki say", "what did the unit teach about", "which week covers", "Obsidian" | the "Second brain" section at the end of this file; `wiki-query` |
| "I'm thinking of…", "what if we switch to…", "new direction", "would X work for the rubric" | the **Direction-check protocol** (end of this file) |
| "ingest this", "Weeks 10–11 are out", "lint the wiki" | `wiki/SCHEMA.md` §6 and `%LOCALAPPDATA%\uni-sync\mma3001-ingest\RESUME.md` |

**Never start a stage whose prerequisite has not passed.** Each file names its own in a callout at
the top. Step 4 in particular is gated on the verification scan's recovered `scan_speed_ms` reading
**10.000, not 20.039** — if it still reads ~20, the parameter path did nothing and there is nothing
worth automating.

### Long-run mechanics

`autoContinueAtUsageLimit` is enabled (`~/.claude/settings.json:86`), so a session that hits the
5-hour limit waits and resumes itself. After **two consecutive** limit hits it stops; recovery is
`/rate-limit-options` → **Wait here, then continue automatically**, which re-arms with no cap.
`/compact` before leaving a long run unattended is worth it — `autoCompactEnabled` is `false`, so a
long transcript only grows and each cold wake pays full freight on it.

## Second brain for the MMA3001 project (wiki, unit content, Obsidian)

The repo root is an Obsidian vault. **Its knowledge base, `wiki/`, exists primarily to serve this
project**: goal §1, rubric §2. Treat it as the first place to look for anything about the unit, the
brief or rubric, the paper, the SWD data limits, validation or Colab portability. Hub:
`wiki/entities/Virtual Surfer Project.md`. The rubric is in `wiki/sources/MMA3001 Project Brief.md`
and `wiki/syntheses/Rubric Criteria Map.md`.

**Where things live:**
- **Unit notebooks:** `Project/Week NN/`, mirrored to `UNIVERSITY/…/MMA3001/Week NN/`, fetched by
  `%LOCALAPPDATA%\uni-sync\mma3001_notebooks.py`.
- **Wiki:** `wiki/`, gitignored (the repo is public), no git history. `wiki/CLAUDE.md` is the query card
  and auto-loads; `wiki/SCHEMA.md` is read only for ingest, lint or schema changes.
- **Ingest toolkit:** `%LOCALAPPDATA%\uni-sync\mma3001-ingest\` (registry, writer spec, digests,
  `merge_contrib.py`, `wiki_lint.py`, `RESUME.md`).
- **Memory:** [memory/](memory/MEMORY.md), committed and shared. Memory holds how to work with
  Benjamin; the wiki holds knowledge. Never duplicate across the two.

**Query protocol (token-lean).**
1. Delegate to the **`wiki-query`** agent (Haiku, read-only). It returns a short cited answer.
2. For a single known fact, use **qmd** (`qmd query "…" -n 5 -l 20`, or MCP `qmd` at local scope) or
   Grep `^aliases:|^# |^rubric:`. Read with `limit: 40` (frontmatter, definition, `## Summary`), then only
   the needed section.
3. Never read `wiki/log.md`; open `wiki/index.md` only to browse; open repo docs only for audit-level
   detail.
4. If the wiki doesn't cover something, say so, then answer from sources, flagged "not yet compiled".

**Direction-check protocol.** This fires when Benjamin proposes or asks about a new direction: a method,
data source, features, scope, validation or baseline approach, or a pipeline change.
1. **Gather** via `wiki-query`, reading Summaries only: *Virtual Surfer Project*,
   *MMA3001 Project Brief*, *Rubric Criteria Map* (plus pages whose `rubric:` includes the affected
   criteria), *Project Validation Evidence and Limits*, *SWD Operating Points Dataset*,
   *Unit Methods Relevant to the Project*.
2. **Return a fit table**, one row per rubric criterion 1–6: what the direction gives, what it still
   needs, and any Poor-band risk. Then check:
   - the brief's non-negotiables: a compared baseline (p.5); validation must-states, including what
     it cannot establish (p.5); a technique taught in the unit (p.7); I/O units and domains (p.4)
   - data limits: one flow speed; group by board
   - unit gaps: no jerk stencil; no double integration
   - timeline: Test 3 in Week 12, and the interview
3. **Cite wiki pages** and label inference. **Never decide** (R12). When Benjamin decides, record it in
   `AI-USE.md` § 4. File the check as a `wiki/syntheses/` page only on request.

**Upkeep:**
- **Ingest** (e.g. Weeks 10–11) follows `wiki/SCHEMA.md` §6 and the toolkit `RESUME.md`. It ends with
  `qmd update && qmd embed`.
- **Lint** with `python "%LOCALAPPDATA%\uni-sync\mma3001-ingest\wiki_lint.py"`.
- **Known tracked-doc errors** (fix only with an R3 ledger entry): `SWD/docs/performance-metrics.md`
  §6 "five phases" (the paper has six); `SWD/docs/project-io-spec.md` §3 "rubric's heaviest item" (the
  rubric is unweighted).

**Obsidian:**
- **Links:** memory notes and wiki pages use `[[name]]`; other repo docs use relative Markdown links
  so they render on GitHub.
- **Link-graph work goes through `/obsidian-memory`** (Obsidian CLI, app open): `unresolved`,
  `orphans`, `backlinks` before a rename or delete, `move to=` for renames, `base:query` for
  `SWD/docs/worklist/worklist.base` and `wiki/rubric.base`.
- **The `obsidian` MCP server** (Local REST API) is live only while the vault is open, and is not used
  for lookups. Delete, binary-write and command-execute are denied in `.claude/settings.json`.
- **Never write note content through the CLI.** Use Write/Edit: the CLI's backslash-t escape turns
  LaTeX `\times` into a tab followed by `imes`.
