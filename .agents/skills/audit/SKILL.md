---
name: audit
description: Independent second-source audit and fix of HYDRODYNAMICS-FIN code — re-test a file, folder or git diff produced by Claude Code, report a VERDICT line with evidence-labelled findings, then fix the Critical/Warning findings with a regression test each and log every fix in AI-USE.md. Use for "audit", "audit and fix", "fix", "SQA", "review", "check", "test" or "second opinion" on code in src/, tests/, SWD/tools/ or tools/. Edits only those folders plus AI-USE.md appends; never commits.
---

# Audit and fix — second-source tester

Goal: catch what the first author's own tests missed, at the lowest token cost, then fix what you
proved. Every finding must come from a command you ran or a line you quoted. The audit (§§ 1–3) is
finished and written down before § 5 edits anything.

## 1. Scope (cheap first)

1. Resolve the target. For a diff: `git -C . diff --stat` then `git -C . diff -- <paths>`. Audit
   the changed hunks plus one hop (direct callers/callees via `grep`), not the whole repo.
2. Read files with line ranges around the change. Do not re-read a file you already have.
3. Pick only the checklists in § 3 that the target touches.

## 2. Run (tiered; stop at the tier that answers)

- **T1, always:** targeted tests `py -3.14 -m pytest tests/<relevant> -q 2>&1 | tail -n 30`, then
  the full guard `py -3.14 -m pytest tests -q 2>&1 | tail -n 5`. For `.ps1`/`.sh`, run
  `lint_probe.py --files <paths>` and the matching `*.Tests.ps1` with `Invoke-Pester`.
- **T2, when a claim needs proof:** write a minimal repro under `%TEMP%\hfin-audit\` and run it.
  A suspected bug with a failing repro is `[Proven]`; without one it is `[High]` at most.
- **T3, only when the user asked about performance:**
  `py -3.14 %USERPROFILE%\.claude\tools\perf_probe.py --mode profile --lang py --run <script.py> [args]`.
  `--run` takes a `.py` file, not `python -m ...`.
- Record the baseline pass/fail count first, so any result you report is a delta against it.

## 3. Checklists (use only the relevant ones)

**ML / numerics (`src/`, `tests/`)**
- Training rows come from `operating_points.csv` (720 rows, 29 boards), never `elements.csv`
  (mesh points, pseudo-replication).
- Every split / CV is **grouped by board** (`src/splits.py`); look for any leakage path.
- `scan_speed_ms` is the physics; `board_speed_setting_ms` is GUI metadata and must never be a feature.
- BJ normalisation: `D` is **net displacement** (double integral of acceleration, Eq 7), not arc
  length; `C = T^5 / D^2`. Ra = θz² / (t1 − t0) (Eq 11).
- The brief requires **at least one baseline** compared with evidence, `pytest` checks against
  **analytical exact cases**, a statement of what validation cannot establish, units/ranges/domains
  for every input with invalid-input handling, NumPy docstrings, and a `pdoc` build that succeeds.
- Floating point: tolerances in tests, division by zero, empty groups, NaN propagation, dtype.

**PowerShell (`SWD/tools/`)**
- Provenance gate intact: nothing deserialised unless its SHA-256 is in the trust manifest; no path
  that skips it.
- Strict mode, `$null` on the left of comparisons, no swallowed errors (`-ErrorAction SilentlyContinue`
  without a check), exit codes of native calls checked.
- BOM-less CSV output; French locale/accents handled (`.claude/rules/swd-technical-facts.md`).
- Nothing writes to the SWD install, library or `SWD/data/`.

**Security / data** — secrets, licence or registry values in code, logs or tests; path traversal;
unsafe deserialisation; `.gitignore` weakened (`*.reg`, `SWD/backup/`, `*.fyn*`).

**Tests themselves** — would the test fail if the code were wrong? Look for asserts on mocks
only, tautologies, and skipped or xfail tests hiding a failure.

## 4. Report — first line is parsed, keep the format exact

```
VERDICT: Critical=N | Warning=N | Suggestion=N
SOURCE: <agy|devin> · <model> · target <path or diff> · baseline <passed>/<total> tests · post-fix <passed>/<total> tests
```
The VERDICT counts what the audit **found**, before any fix, so the parser still sees every defect.
Append ` (CLEAN)` to the VERDICT line when Critical=0 and Warning=0. Then:

- **Findings**, one line each: `C1 [Proven|High] file:line — defect — consequence — fix`.
  Severity: Critical = wrong results, data leakage, safety/licence breach, crash on valid input.
  Warning = edge-case failure, missing required validation, >20% slowdown. Suggestion = hygiene.
- `[Needs-info]` items go under **Open questions** and never count toward the VERDICT.
- **Fixes**, one line per Critical/Warning finding:
  `C1 fixed|skipped (no proof)|reverted|proposal (R12) — file:line — test added — guard result`.
- **AI-USE entries appended**: which § 2 / § 5 entries you added.
- **Explain before submission**: every module you touched (R7).
- **Commands run**, one line each, with the headline result.
- **Not checked**: what you skipped and why. An honest gap beats implied coverage.
- End with: `Unreviewed: fixes need sign-off from a fresh reviewer; nothing is committed.`

Keep the whole report under ~80 lines. No preamble, no restating the code.

## 5. Fix (after the findings are written)

1. Order: Critical, then Warning, then by file. Suggestions are never applied.
2. A finding that is really a design choice (method, features, split strategy, scope, what to
   report as a failure) is marked `proposal (R12)` and left alone. The student decides those.
3. For each remaining finding:
   1. Add a regression test that **fails** on the current code: `tests/test_*.py`, or a
      `*.Tests.ps1` for `SWD/tools/`. No failing test means `skipped (no proof)`, not a blind fix.
   2. Make the minimal-diff fix in `src/`, `tests/`, `SWD/tools/` or `tools/`. No refactor, no new
      dependency.
   3. Run the new test, then the guard `py -3.14 -m pytest tests -q 2>&1 | tail -n 5`; for `.ps1`
      also `lint_probe.py --files <paths>` and the matching Pester file.
   4. Guard worse than the baseline: revert that fix and its test, and mark it `reverted`.
4. For each fix that lands, **append** to `AI-USE.md`, matching the format of the entries already
   there:
   - § 2 task log (R2): date, `<agy|devin> <version> · <model>`, the prompt you were given verbatim,
     what changed, how it was verified (the test name and guard result).
   - § 5 errors ledger (R3), only when the fix corrects an earlier AI error: date, what was
     believed, what was true, how it was caught, who caught it.
   Never edit, reword or delete an existing entry, and never touch § 6 or `README.md` (R1, R10).
5. Never edit, skip, xfail or delete an existing test or assertion, `pyproject.toml` test config, or
   anything under `%USERPROFILE%\.claude\`. Never run SWD or a hydroscan driver to "check" a fix.
6. Never commit or push. `git -C . diff --stat` goes in **Commands run** so the reviewer sees the
   whole change set.
