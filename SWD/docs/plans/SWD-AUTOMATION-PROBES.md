---
type: plan
status: todo
worklist: SWD/docs/worklist/06-swd-automation-probes.md
---

# SWD automation probes: test each fiddling technique before building the evening rig

**Stage plan, written 2026-09-30.** Standalone. The evidence behind every test is in the wiki:
`wiki/syntheses/SWD Automation Technique Register.md`, whose **untested** rows are these probes.
They come from two AI research reports (`Research for Automation/`, gitignored) that were checked
against primary sources on 2026-09-30.

> ### 🚦 Prerequisites: do not start otherwise
> - Backups exist at `%USERPROFILE%\SWD-backup\<date>\` (repo `CLAUDE.md` § 4).
> - SWD is open with an **unlocked copy** board, never an original. Benjamin's hand-run copy (e.g.
>   `blueTreck_Copy_3`) is the default; T1 confirms its lock and scan state.
> - **Night conditions:** the external monitor is unplugged, and SWD sits on the 3200×2000 panel at
>   175%.
> - Claude Code runs **elevated** (SWD is High integrity; `AI-USE.md` E16/E17), with the deny rules
>   in `UNIVERSITY/.claude/settings.local.json`. They must be verified in-session by a refused `Read`
>   of a dummy `.reg` and a refused write under a `ShaperWaveDynamics` folder.
> - **Stage 2 only:** `SWD/tools/phase2/swd_probe.ps1` has passed the one-pass SQA (`CLAUDE.md` § 4).

## Rules for every probe

- **Denylist, never actuated:**
  - Hydrodynamics Scanner / No Hydroscan, Delete hydroscan and UnLock
  - the context-menu items Create, Rename, Delete and Share (only `Open` is allowlisted)
  - File → Save project, and every Export
- **Reuse, do not rebuild:** `swd_msg.ps1`, `swd_board.ps1`, `swd_diagnose.ps1`, `verify_2b.ps1`
  (see the register).
- **Logs** go to `%LOCALAPPDATA%\swd-probe\<yyyy-mm-dd>\`, one file per probe, UTF-8 without BOM.
  Nothing is written in the repo or the library.
- **Library hash** (`Get-BoardHash`) before the first probe and after the last; the two must be
  identical. Then run `swd_extract.ps1 -TrustCurrentLibrary -OutDir <scratch>`, never without
  `-OutDir` (E84).
- **Session mechanics:** foreground commands of 10 minutes or less, no `run_in_background`, and
  every shell command shown for approval.
- **Hand steps are question rounds** (memory `feedback-swd-ask-before-automating`): Benjamin drives
  Inspect or AccEvent, and Claude asks what they show.

## Stage 1: Seeing (read-only)

| T | Probe | Method | Pass or record |
|---|---|---|---|
| T1 | Integrity and pinning | `Format-Integrity` for SWD; pin the main window by class, owner and title; read `HKCU\…\AppCompatFlags\Layers` for a RUNASADMIN flag (never the `swdy` key) | SWD integrity and its cause, if found |
| T2 | Win32 census per tab | `swd_diagnose.ps1` sections A–E on the Shape, Fins, Board Aspect and Shaper Report tabs | 4 control maps; visible, hidden and text counts |
| T3 | UIA/MSAA reach | Inspect.exe on grid rows (Name, Value, IsReadOnly, LegacyIAccessible Value/State, bold vs not), tree items, menu items, a FlatStyle checkbox, tab items, and the Fins L/D readout | per element: readable through UIA, MSAA, or neither |
| T4 | Capture | `Save-SwdWindowImage` against Pillow `ImageGrab` of the same rectangle, with the 3D view on screen | is the 3D region black or stale? bitmap size vs rect; ms per capture |
| T5 | Idle noise | 60 s at 2 fps idle; `swd_diff.py`: tile equality vs SSIM | volatility mask; false positives and CPU ms per method |
| T6 | Events | AccEvent.exe (WinEvents + UIA events), while Benjamin switches a tab, edits a grid value, and presses Apply Length | which events fire, for what |
| T7 | OCR (only if T3 leaves text unreachable) | `Windows.Media.Ocr` en-US on a crop with a known value | accuracy and ms |
| T8 | Clipboard | Hand question first: where do Copy / Paste / Merge Section live? Then clear → invoke → `GetClipboardSequenceNumber` → formats | formats and parseability |

## Stage 2: Acting (scratch board, after the SQA gate)

| T | Probe | Method | Pass or record |
|---|---|---|---|
| T9 | Write and read back | `Set-SwdNumeric` on Surfer Kg, then restore | read-back equals written; decimal rendering |
| T10 | Clicking in the background | `Invoke-SwdButton -Post` on Apply situation with another window in front; `Compare-SwdMap` + image diff | effect observed or not |
| T11 | Tab and grid writes | UIA `SelectionItem.Select` on tabs; `ValuePattern.SetValue` on grid `Nom` against keyboard entry | read-back |
| T12 | Reset fidelity | File → Open Board (full path into the `#32770` filename edit) or `Invoke-SwdMenuItem -Allow 'Open'`; compare maps and images with the baseline | identical = exact reset |
| T13 | Settle rule | 10 × Apply Length (+x, then back): time settle by `WM_NULL` probe, SWD CPU below 2.5%, and K identical frames | settle-ms distribution per rule |
| T14 | Detector controls | Positive: declare only the Length box, then Apply Length; W/T/V, title and 3D view must be flagged out-of-scope. Negative: a no-op click gives zero changes after the mask. Run each twice | detected / clean / deterministic |

## Stage 3: Throttling and safety

| T | Probe | Method | Pass or record |
|---|---|---|---|
| T15 | Resource signals | psutil (system CPU, available memory, SWD CPU and working set) + GPU Engine counter; sampler overhead | proposed pause thresholds |
| T16 | Keep-awake, lock and lid | read the AC lid action and sleep/lock timeouts (`powercfg /q`); `SetThreadExecutionState`; lock with Win+L, then retry `WM_GETTEXT`, `WM_SETTEXT` and PrintWindow; list scheduled tasks in the night window | whether night runs need an unlocked screen or open lid |
| T17 | Kill switch | stop file checked between steps + cursor-in-corner abort, on a dummy loop | stops within one step |

## After the session

1. **Wiki:** a `sources/SWD Automation Probe Results <date>.md` page and a raw copy (answers
   verbatim, redacted per R9). Update the register's rows with `> [!note] Updated` callouts. Then
   index, log, `qmd update && qmd embed`, and lint.
2. **`AI-USE.md`:** a § 5 ledger row for each premise the probes overturn; Benjamin's rig decisions
   in § 4.
3. **Worklist item 06:** set to `done` or `failed`.
4. **The evening-run plan** (`SWD-FIDDLE-EVENING-RUN.md`) is written only when all of these hold:
   - T12 reset is exact
   - T14's positive control is detected and the negative is clean
   - T15 thresholds are set
   - T16 and T17 pass
   - the runner has passed its SQA pass

## Results

Detail: `wiki/sources/SWD Automation Probe Results 2026-09-30.md`. Logs:
`%LOCALAPPDATA%\swd-probe\2026-09-30\`. Board `blueTreck_Copy_4` (scanned, so locked).

| T | Date | Result | Log |
|---|---|---|---|
| T1 | 2026-09-30 | ✅ SWD High integrity (manifest `highestAvailable`, no compat flag); probe High; main window pinned; 25 top-level windows | `T1a-compat.txt`, `T1b-T2-summary.txt` |
| T2 | 2026-09-30 | ✅ 181 controls, all read, 0 timeouts, 98 ms; the board-info EDIT gives geometry as text | `T2-control-map-initial.csv` |
| T3 | 2026-09-30 | ✅ Managed UIA client poor (137 bare elements). UIA3 + MSAA (`comtypes`): 233 elements, 100 designer ids, 18 values, checkbox states, tabs, tree; **analysis grid 77 rows incl. `Moment_yaw_hydrodynamic_nm`**; MSAA read-only 64/13 (bold match unchecked) | `T3-uia3-*.csv/json` |
| T4 | 2026-09-30 | ✅ PrintWindow captures the DX11 view at native 1845×1111 (SWD DPI-unaware); the 3D view renders late after load; ⚠️ covered-window capture not achieved | `T4/` |
| T5 | 2026-09-30 | ✅ 26 noise tiles (status bar, slider area); 30-s hold-out 0 false changes; tile equality = SSIM result at 4.5 vs 245 ms | `T5-idle.json`, `T5-holdout.json` |
| T6 | 2026-09-30 | ✅ WinEvents trace tab switches and Apply Length's knock-on changes (8 distant controls, settled in 3.4–7.2 s) | `T6-winevents.csv`, `T6-summary.json` |
| T7 | 2026-09-30 | ➖ not needed: all text reachable via UIA3/MSAA | — |
| T8 | 2026-09-30 | ❌ no clipboard route: the grid menu is Rail / Coupe complete; clipboard unchanged | `T8-result.json` |
| T15 | 2026-09-30 | ✅ psutil at 20 Hz = 0.23% of the machine | `T15a-sampler-overhead.json` |
| T16 | 2026-09-30 | ◐ settings: on AC never sleeps, lid does nothing; night tasks 03:30, 04:27, 04:30, 04:50, 07:30. Lock test still owed | `T16a-power-schedule.txt` |
| Library | 2026-09-30 | ✅ after Stage 1 only SWD's own `temp\image_dessous.png` changed; exclude `temp\` from the invariant | `library-hash-*.csv/txt` |
| Backup | 2026-09-30 | ✅ `%USERPROFILE%\SWD-backup\20260930\` (licence `.reg` 304 B, `user.config`, `biblio\` 447 files / 880.5 MiB); mirror hash-identical to the live library | `backup-verify.txt` |
| T9 | 2026-09-30 | ✅ write + read-back + restore work (invariant culture, settle 1.25 s). ⚠️ **Residue:** writing the volume target box renames the Apply Volume button to 'Set N liters volume to board', restoring the box does not rename it back, and a board reload does not reset it. Run T9 last | `*-T9/` |
| T10 | 2026-09-30 | ✅ Apply Length clicks land with SWD in the **background** (foreground = the terminal; not minimised): ±1 mm both ways, round trip exact | `215459-T12/` |
| T11 | 2026-09-30 | ✅ tab switch by `TCM_SETCURFOCUS` (message): page shown, WinForms handlers ran, cursor unmoved, back-vs-original = 0. ❌ MSAA default action on a tab is a **real mouse click** (moved the cursor) — removed | `210729-T11/` |
| T12 | 2026-09-30 | ✅ **first automated Apply Length**: label ±1 mm / ±0.06 L, title follows. First round trip NOT exact (the first Apply switches the 3D camera to a top view and fills four empty fields, '40' and '0,01'); every later round trip exact | `214519-T12/`, `214633-T12/` |
| T13 | 2026-09-30 | ✅ 6 clicks, 0 timeouts; settle after the label poll 1.21–2.12 s (mean 1.66); responsive at ~0.27 s, CPU quiet at ~0.7 s, frames bind; plus 1.9–3.0 s inside `Set-SwdGeometry` → ~4–5 s per action | `214734-T13/t13-settle.csv` |
| T14 | 2026-09-30 | ✅ **detector works**: negative (null action ×2) clean on all channels; positive (Apply Length ×2) identical both runs, 3 in-scope, 26 out-of-scope (Width 680.5888→680.9078 by homothety, inch boxes, volume label, Configuration, 'Section 5 at' label, title, 14 image regions) | `214852-T14/` |
| T17 | 2026-09-30 | ✅ stop file stops the loop after step 3 (unit + live) | `215102-T17/` |
| T16 lock test | — | owed: Win+L during a probe | — |

## SQA handoff (for tonight's pass)

Owner override, 2026-09-30 (`AI-USE.md` § 4): `swd_probe.ps1` was run live **before** SQA.

**In scope:**
- `SWD/tools/phase2/swd_probe.ps1` (new)
- `SWD/tools/phase2/tests/swd_probe.Tests.ps1` (new, 118 tests)
- `SWD/tools/phase2/swd_diff.py` (new, self-check)
- `SWD/tools/phase2/swd_geometry.ps1` (**one change**: the Volume apply-button resolver also accepts
  `^Set \S+ liters volume to board$`; 2 tests added, 28/28)

**Status when handed over (whole phase2 suite, SWD closed, elevated session, 2026-09-30 22:00):**
520 of 567 pass.

| Suite | Result |
|---|---|
| `swd_probe` | 118/118 |
| `swd_geometry` | 28/28 |
| `swd_geometry_verdict` | 16/16 |
| `swd_board` | 44/44 |
| `verify_2b` | 103/103 |
| `swd_msg` | 201/237 |
| `swd_diagnose` | 10/21 |

PSScriptAnalyzer: 0 findings on `swd_probe.ps1` and `swd_geometry.ps1`.

**The 47 failures are all in the two throwaway-target fixtures** (`swd_msg` "Dialog layer" and
`swd_diagnose` "section F"), which fail in their own setup.
- `swd_msg.ps1`, `swd_diagnose.ps1` and both test files are **unchanged** from git HEAD
  (`git status`), so these failures are not caused by tonight's changes.
- Pester reports an escaped `break`/`continue`.
- Replayed outside Pester, the fixture's `Process.MainWindowHandle` is non-zero when first found
  and **0 a moment later**, so its `Get-SwdProcess` stub throws 'target has no main window'. That
  is the same instability `LIVE-RUN-FINDINGS.md` recorded for SWD.
- **Root cause not established.**
- The recorded 447/447 baseline was not taken in an elevated session with a second monitor attached.
  **Re-run these two files from a normal (unelevated) terminal first**, before treating them as a
  regression.

**Bugs found and fixed live, each with a regression test:**
- `@(List[object])` throws "Argument types do not match" on 5.1
- the `$x = if (...) { @() }` unroll, which gave `$null` and a single unrolled box
- a double-wrapped `Get-SwdDescendant` result
- MSAA title-bar echo double-counted every edit
- MSAA window-object names double-counted renames
- index-path MSAA keys gave 1,103 false changes (now window-anchored, hidden-aware)
- status-bar noise names carry a leading space
- the (1280,128) noise tile was missing from the image filter
- the MSAA tab default action simulated a mouse click
- `Test-SwdOwnsForeground` was called with SWD's own handle
- `Deltas` is a dictionary, not an object
- the kill-switch corner fired on a left-hand monitor

**Open points for the reviewers:**
1. **`Set-SwdGeometry` false negative.** It sends a blocking `BM_CLICK`, gets 1460 on SWD's slow
   Apply handler, and returns `Applied=False` / 'apply-click-not-transported' for clicks that
   landed. The probe judges actuation from the label deltas instead. The fix in `swd_geometry.ps1`
   is not made (`-Post`, or treat 1460 plus a matching delta as applied).
2. **The `Set-SwdGeometry` resolver requires all three axes**, so one unresolvable axis blocks the
   others.
3. **`LeavesResidue` in T9 is only as good as its baseline.** A run started from an
   already-changed state reports none.
4. **The MSAA walk sees about 3,000 nodes** (about 3.3 s per snapshot). Check the depth and node
   caps, and the COM exception handling on a busy SWD.
5. **Denylist and allowlist wording:** `ProbeDenyPattern`, `ProbeAllowedButtons`,
   `ProbeAllowedTabs`.
