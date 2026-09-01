# Board-geometry surrogate — worklist

Live checklist for the ML workstream. `SWD/TODO.md` remains the acquisition-side list.
Plan: `~/.claude/plans/could-you-do-some-purring-lamport.md`.

**Keep the status column current. A stale checklist is worse than none.**

---

## Tier 0 — extraction (no SWD time)

| # | Step | Status |
|---|---|---|
| 0.1 | Run `extract_board.ps1` over the 13 other scanned boards | ✅ 2026-09-01 — 13/14 `board.csv` |
| 0.2 | Cross-board variation of the 53 board columns | ✅ 36 vary, 16 constant |
| 0.3 | Recover Length/Width + Thickness/Length, check vs SWD's panel | ✅ 0.03% / 0.05% |
| 0.4 | `default_shortboard_Copy_1` refused by provenance gate | ⛔ **BLOCKED — needs user decision** (content changed 2026-09-01 21:19) |

## Tier 1 — ML pipeline (no SWD time)

| # | Step | Status |
|---|---|---|
| 1.1 | `requirements.txt`, `pyproject.toml`, `src/`, `tests/`, `docs/` | ✅ |
| 1.2 | `src/geometry.py` — L/W, T/L, absolute-size reconstruction | ✅ 21 tests |
| 1.3 | `src/data.py` — training table, feature/target spec, exclusions | ✅ |
| 1.4 | `src/splits.py` — board- and family-grouped splitters | ✅ 21 tests incl. planted leak |
| 1.5 | `src/models.py` — SVR, tree, 5-NN, mean floor; signed-log target | ✅ |
| 1.6 | `src/evaluate.py` — LOBO, per-fold **and** pooled | ✅ |
| 1.7 | `src/physics_baseline.py` — SWD's own friction law + 1-parameter baseline | ✅ written, validated to 7.5% |
| 1.8 | `src/predict.py` — query API with envelope checking | ✅ |
| 1.9 | `tests/test_physics_baseline.py`, `tests/test_predict.py` | ✅ **85 tests passing** |
| 1.10 | `pdoc` HTML into `docs/` | ✅ 7 modules |
| 1.10b | `README.md` (+ humanizer pass, fact-diff PASS) | ✅ |
| 1.10c | `LICENSE` | ✅ MIT + third-party section |
| 1.11 | Profiling pass (`src/profiling.py`) | ✅ 0.709 ms/board vs 12–31 min; AI 0.625 FLOP/byte; 24× batching gain |
| 1.12 | Git: branch, meaningful commits (rubric item 2, currently 3 commits, `SWD/` untracked) | ⬜ |

## Tier 2b — UIA board switching (user-requested; headless prerequisite)

| # | Step | Status |
|---|---|---|
| 2b.1 | Write `SWD/tools/phase2/swd_board.ps1` — UIA select + menu invoke | ✅ parses 5.1 + 7, PSSA clean |
| 2b.2 | Write `SWD/tools/phase2/swd_geometry.ps1` — Get/Set geometry, triple oracle | ✅ parses 5.1 + 7, PSSA clean |
| 2b.3 | Pester suite, synthetic control-list fixtures | ✅ **21/21 passing** |
| 2b.4a | SQA round 1 (`sqa-lead` → functional + security + efficiency) | ✅ `C=2 \| W=16 \| S=17` |
| 2b.4b | Fixer round (`code-reviewer`, findings handed over verbatim) | ✅ `C=0 \| W=0 \| S=2` — 2 suggestions deferred with reasons, 1 rebutted |
| 2b.4c | New tests for findings 14 & 15 (written independently of the fixer) | ✅ `swd_board.Tests.ps1` 23, `swd_geometry_verdict.Tests.ps1` 16 |
| 2b.4d | Fresh `sqa-lead` verification, round 2 | ✅ `C=2 \| W=6 \| S=9` — fixer's CLEAN did not hold |
| 2b.4e | Fixer round 3 (same agent, findings verbatim) | ✅ `C=0 \| W=0 \| S=2` — **also found a 3rd Critical itself** |
| 2b.4f | Close the two test-coverage findings that were mine | ✅ 318 → **333 tests**, all passing |
| 2b.4g | Mutation sweep over the round-3 test additions | ✅ **8/8 non-equivalent killed**; 1 documented gap (`:705` re-ident, needs a live UIA element) |
| 2b.4h | Fresh verification round 3 | ✅ **`C=0 \| W=2 \| S=13`** — cap reached, not CLEAN |
| 2b.4i | Fix the 2 remaining Warnings | ✅ **unverified by an independent pass** — see below |
| 2b.4j | Write the QA ledger entry (`~/.claude/qa-history/swd-phase2.md` RUN 2) | ✅ + § 2 re-measured |
| 2b.5 | Live verify with SWD open: select each of 29 boards, confirm via window title | ⬜ needs SWD |
| 2b.6 | Confirm whether Save-As is reachable via `InvokePattern` | ⬜ needs SWD |

## Tier 3 — scan the 13 unscanned hulls (2.6–6.7 h SWD)

| # | Step | Status |
|---|---|---|
| 3.1 | Back up `rapports_hydro/` before first scan | ⬜ |
| 3.2 | `swd_scan.ps1` — dialogs, resumable state, run manifest | ⬜ |
| 3.3 | SQA on `swd_scan.ps1` | ⬜ |
| 3.4 | Scan 13 boards, extract, re-approve trust manifest each time | ⬜ |
| 3.5 | Re-run evaluation on 26 hulls; compare against the 13-hull result | ⬜ |

## Tier 4 — geometry sweep (11–28 h SWD)

| # | Step | Status |
|---|---|---|
| 4.1 | **One verification variant end to end**, acceptance declared first | ⬜ gate |
| 4.2 | Establish what Apply Length/Width/Volume actually do (never measured) | ⬜ |
| 4.3 | 5-point × 2-axis × 6-parent sweep = 54 scans | ⬜ |
| 4.4 | Retrain, compare within-family vs across-board | ⬜ |

## Documentation corrections owed

| # | Item | Status |
|---|---|---|
| D.1 | `CLAUDE.md:169` + QA ledger § 2 — "29 boards" → 14 scanned | ⬜ |
| D.2 | `coverage.md` — 667 rows / 27 boards / 2 speeds, all stale | ⬜ |
| D.3 | `project-io-spec.md:302-306`, `TODO.md:706-711` — retracted homothety still asserted | ⬜ |
| D.4 | `project-io-spec.md:130`, `DATA-DICTIONARY.md:33-36` — sentinel filter stale | ⬜ |
| D.5 | **`CLAUDE.md` § 5 friction-velocity bullet is misleading** — measured 2026-09-01: using stored `board_speed_setting_ms` gives ratio 0.243 (76% error); scan speed gives 0.941. SWD overwrites the field before solving | ⬜ |

## ⚠️ Observable-behaviour changes needing sign-off before the live run

The fixes changed surfaces you can see. All were required by the findings, none weaken a guard.

| Change | Consequence |
|---|---|
| `Invoke-SwdMenuItem` gained a **default-deny `-Allow`** | The batch driver must be written `-Allow 'Save As...' -Confirm:$false`. Nothing is invocable otherwise |
| `Set-SwdGeometry -Tolerance` is now **absolute**, per axis (0.5 mm / 0.005 L) | Was relative 0.02, i.e. ±42.7 mm on a 2134 mm board |
| `Set-SwdGeometry` result gained 9 fields, `Applied` is strictly stricter | A board **already at target** now returns `Applied=$false`, `already-at-target` |
| `Select-SwdBoard` gained `AlreadyLoaded` and `title-unreadable` | |

**Consequence for the first live run:** it must start from a board that is *off* target, or
it proves nothing about whether the Apply buttons actuate.

## Findings to carry into the report

- Geometry collapses to **1 dimension** in the corpus CSVs; recovered to **3** from `board.csv`.
- **Friction drag is the only target that generalises** to an unseen hull: R² median +0.37,
  10/13 folds positive. Planing, total and lift do not (R² median −0.5 to −0.3).
- Geometry features help on **every** target, so the axis is real — there is just too little of it.
- The prior "+0.52" baseline is **pooled, log-space, friction**. The same predictions score
  **−0.485 per-fold in newtons**. Report both, never one.
- **The drag decomposition is not additive**: friction+planing+rail ≠ total on 0 of 720 rows.
- Recovered friction law reproduces SWD to **7.5% median**, not the 1–3% previously recorded.
- **Two real bugs the Pester suite caught before any live run**: PowerShell unrolls an
  empty returned array to `$null`, so `.Count` threw under StrictMode in three functions;
  and `$matches` shadowed the automatic `$Matches` the same file relies on for the
  board-title parse.
- Backup before SQA: `~/.claude/qa-backups/20260901-232425-swd-uia-geometry/`
- **The third Critical, found in round 3 and missed by two SQA rounds:** `return ,$out`
  piped straight into `Where-Object` makes `$_` the whole array, so `@(f).Count` returns 1
  for a 2-element result. It read as working only because `array -eq 'x'` is a *filter*
  whose non-empty result is truthy. Whole-repo idiom risk — worth grepping `swd_msg.ps1`
  and `swd_diagnose.ps1` for `return ,$` followed by a direct pipe.
- **A stub more forgiving than the function it replaces hides the bug it should catch.**
  My `Get-SwdMenuItem` mock streamed its items while the real one returns `,$out`; that is
  what let the Critical above hide. Fixture return shapes must match exactly.
- **A `[string]` parameter coerces `$null` to `''`.** My `New-State` fixture did this, so a
  test named "the BEFORE read failed" was constructing "answered empty" instead — the exact
  distinction under test. Same trap the source carried at `[AllowNull()][string]`.
- **A bare `Should -Throw` can pass for the wrong reason.** The homoglyph test passed while
  its mutant survived, because the throw came from a null `Element`, not the gate. Assert
  the message.
- **Passing the same string to both sides cannot distinguish ordinal from linguistic.**
  `-Name $homoglyph -Allow $homoglyph` admits under either comparison, so the gate mutant
  survived. `-Name $homoglyph -Allow 'Save'` is what pins it.

## ⚠️ Incident — 2026-09-02, mutation harness left a live mutant

The coordinator's mutation harness restored source files *after* each iteration rather than
in a `finally`. It blocked on a hung subprocess, was killed, and left mutant M5d live in
`swd_board.ps1` for ~25 minutes: line 471's board-name selector sat as linguistic `-eq`
instead of `[string]::Equals(..., OrdinalIgnoreCase)`.

**Three failures, and only the last one caught it:**
1. No `try/finally` — restoration was a statement after the work, not a guarantee.
2. The integrity check compared against a remembered number (`expected 5`) rather than a
   measured one. The true count is 6 (5 code sites + 1 comment), so the check reported
   healthy on a corrupted file.
3. The first instinct on two failing tests was that the tests were wrong. They were right.

**Restored and verified by measurement:** `swd_board.ps1` SHA-256 `E11268D2A5FEB721`,
matching the pre-mutation snapshot; 5 `[string]::Equals` sites at 471, 520, 655, 667, 705;
parse OK on both hosts; PSSA 0; 339/339 passing.

**Harness hardened:** `try/finally` per mutant, plus `atexit` and SIGINT/SIGTERM handlers
that restore before exit, with the incident recorded in its docstring. Re-run afterwards:
4/4 killed, byte-identical restoration confirmed.

**Open finding handed to the verifier:** `swd_board.ps1:450` computes `$alreadyLoaded` with
linguistic `-eq` while the selector below uses ordinal. **Verdict: not exploitable.** An
exhaustive sweep of all 973 BMP single-character case pairs found zero strings where ordinal
says equal and `-eq` says not, and PowerShell's `-eq` is *invariant*-culture, not ambient — so
a tr-TR host does not open it. Its error direction is conservative (discards valid evidence
rather than manufacturing it). **Fix it before WP3 Step 4 is written**, since it stops being
cosmetic the moment a batch driver branches on `AlreadyLoaded`.

## ⚠️ SQA loop closed at its 3-round cap — NOT clean

Final: **`Critical=0 | Warning=2 | Suggestion=13`**. Both Warnings were then fixed by the main
session and **have had no independent verification**:

1. `swd_board.ps1` `Select-SwdBoard` validated neither `-PollMs` nor `-TimeoutMs`, so
   `-PollMs -1` threw *after* `Select()` had acted. The identical guard already existed in
   `Set-SwdGeometry` and had not been copied across. Now guarded + 2 tests.
2. `tests/swd_board.Tests.ps1` claimed completeness it did not have — `Get-SwdWindowTitle`
   had zero coverage and was absent from the file's own "NOT COVERED" list. Now 3 contract
   tests plus an honest, expanded gap list.

**13 Suggestions remain unaddressed and are recorded in the ledger**, the notable ones being
two more linguistic `-eq` sites (one of which selects *which Apply button is clicked*),
fixtures that hardcode `Agree=$true` / `ApplyEnabled=$true` and so leave five round-3 guards
unpinned, and ~5.7 KB of duplicated comment blocks.
