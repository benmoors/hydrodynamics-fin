# SQA findings — phase2 automation, 2026-08-27

**`VERDICT: Critical=6 | Warning=11 | Suggestion=14`**

Produced by `sqa-lead` + `sqa-functional`, `sqa-security`, `sqa-efficiency` against
`swd_msg.ps1` and `swd_diagnose.ps1`. Reproduced here verbatim because the agent could not write to
disk (no `Write` tool, and its Bash guard refuses redirects into the repo), so this file is the only
copy.

**Status: all 32 were disposed by a `code-reviewer` intake round on 2026-08-27**, then independently
verified by a fresh `sqa-lead`, which returned `Critical=1 | Warning=4 | Suggestion=8` — one new
Critical and three regressions created by the fixes themselves. Round 2 is in progress.

Treat this file as the **original worklist**, not as a status board. The live state is in
[`SWD/TODO.md`](../../TODO.md); the loop record is in `~/.claude/qa-backups/20260827-193428-swd-phase2/`.

`[Proven]` = demonstrated by measurement. `[High]` = strong evidence, not directly demonstrated.
Every `[Proven]` behavioural finding was reproduced against a throwaway in-process WinForms harness —
**SWD itself was never contacted**.

---

## Critical

**C1 — `Invoke-SwdButton` reports success it cannot know.** `[Proven]` `swd_msg.ps1`
`Ok` is `SendMessageTimeout`'s **transport** status; `BM_CLICK`'s own result lands in `$res` and is
discarded, so `Ok=$true` comes back when nothing happened. Measured: click on a plain Label →
`Ok=True`; on a **disabled** CheckBox → `Ok=True`.

**C2 — the click probe's detector is blind on WinForms controls.** `[Proven]` `swd_diagnose.ps1`
`BM_GETCHECK` returns 0 for a `FlatStyle=Standard` CheckBox that is genuinely checked (the same
control at `FlatStyle=System` returned 1), and SWD is entirely `WindowsForms10.*`. An unfocused
`BM_CLICK` that **did** toggle the control is reported as "No observable state change" — corrupting
the single measurement the whole headless route rests on.

**C3 — a bad value mutates the control, then throws.** `[Proven]` `swd_msg.ps1`
`[double]$Value` is evaluated **after** the `WM_SETTEXT`. Measured: the control had already moved
12.50 → 30 when the cast threw, and the caller got no `Before`/`After`/`Ok` record at all. Under
`$ErrorActionPreference='Stop'` the run aborts with SWD in a changed, unlogged state.

**C4 — `-Activate` is inert and says otherwise.** `[Proven]` `swd_msg.ps1`
`SetActiveWindow` only acts within the calling thread's own message queue. Measured cross-thread: it
returned `IntPtr.Zero`, foreground unchanged — and the return value is discarded, so `Activated`
reflects the switch, not the outcome. The diagnostic tells the operator to "Retry with `-Activate`",
so the documented fallback for the project's central open question cannot work *and cannot be seen to
fail*.

**C5 — a NULL parent enumerates the whole desktop.** `[Proven]` `swd_msg.ps1`
`Get-SwdControl` passed `$p.MainWindowHandle` to `EnumChildWindows` with no zero-check. Measured:
`Children([intptr]0)` returned **479 windows belonging to other processes**. `control-map.csv` then
fills with foreign windows, `WM_GETTEXT` reads all 479, and the diagnostic's guard accepts any of
them — so `BM_CLICK` lands in **another application** while the log says "child window of SWD".
Reachable while SWD is starting, hidden, or exiting mid-run.

**C6 — a timeout is never distinguished from an answer.** `[Proven]` both files
`$null` (timeout) is a well-designed signal that **no consumer tests for**, and no caller counts
timeouts. In section F, `$null -ne ''` is True, so a timed-out first read plus an empty second read
prints "**THE CLICK LANDED WITHOUT FOCUS**" from a run that measured nothing; `$null -ne $null` is
False, so two timeouts print "No observable state change". In the enumeration, a fully-hung SWD
returns 181 rows with `Text=$null` in milliseconds and section E logs "controls whose text mentions
scan/hydro/drift/speed: **0**" — indistinguishable from a genuine zero.

---

## Warning

**W7 — no target validation before a state-changing message.** `[Proven]`
The library accepts any `[int64]$Handle` with no check it belongs to SWD; the diagnostic checks
handle membership but never gates on `Class` or `Enabled`, which it reads only for the log. Measured:
`BM_CLICK` operates a **disabled** WinForms control, bypassing the application's own precondition
guard. The map the operator picks from lists `Reset outline`, `Clean Shape` and `UnLock` as
"BM_CLICK targets".

**W8 — the script asserts a claim its own notes refute.** `[High]` `swd_diagnose.ps1`
Section C's else-branch states unconditionally that "lastError=5 … means another process holds the
block", and is not even gated on `$blockErr`. Sends the operator hunting a process that does not
exist.

**W9 — `control-map.csv` has a BOM.** `[Proven]` `swd_diagnose.ps1`
`Export-Csv -Encoding UTF8` writes a UTF-8 BOM under 5.1; the live file begins `ef bb bf`. Violates
[`CLAUDE.md`](../../../CLAUDE.md) § 5. The log was fixed for exactly this trap; the CSV — the file downstream Python
actually parses — was missed one line away.

**W10 — the two sides of the equality parse in different cultures.** `[Proven]` `swd_msg.ps1`
`TryParse` uses current culture, `[double]$Value` uses invariant. Measured under fr-FR:
`TryParse("10.5")=False` while `[double]"10.5"=10.5`; `TryParse("10,5")=10.5` while
`[double]"10,5"=`**`105`**.

**W11 — `-WhatIf` is indistinguishable from failure, and is not inert.** `[Proven]` `swd_msg.ps1`
Returns `Ok=False` with populated `Before`/`After`, and the pre-read sends two messages to the live
control **before** `ShouldProcess`. A scan driver cannot rehearse.

**W12 — `Save-SwdWindowImage` returns a path on failure.** `[High]` `swd_msg.ps1`
Every other exit returns `$null` on failure, so "a path means success" is the established contract —
broken on the one path that yields a blank PNG.

**W13 — an empty UIA tree prints the opposite conclusion.** `[High]` `swd_diagnose.ps1`
With `$all.Count -eq 0`, `Keys.Count -le 1` is True but `ContainsKey('Pane')` is False, so control
falls through to "Named control types are visible, so UIA can reach the provider."

**W14 — sections E and F are unguarded under `Stop`.** `[High]` `swd_diagnose.ps1`
Section D is wrapped; E and F are not. Any throw kills the run before the Summary, and because `Log`
only writes what it is handed, the exception **never reaches the log file** — the artifact ends
mid-section with no marker.

**W15 — `-LogDir` is unvalidated.** `[Proven]` `swd_diagnose.ps1`
Two limbs. (a) Measured with `git check-ignore`: the default path is ignored, but
`SWD/tools/phase2/20260827-diagnose.log` matches **no rule at all** — and the log carries the account
name, full home paths and SWD's window title (board name, surfer mass). (b) `New-Item -Force` has no
containment check, so an elevated run will create a directory inside
`C:\Program Files\ShaperWaveDynamics\` on request — **a [`CLAUDE.md`](../../../CLAUDE.md) § 4 hard rule with no code
enforcing it.**

**W16 — no `*.png` rule anywhere in `.gitignore`.** `[Proven]`
`Save-SwdWindowImage -Dir` is unvalidated and PNG coverage is incidental, via the `logs/` directory
rule alone. The PNG is a full render of SWD's window.

**W17 — target-controlled text forges the log's line structure, today.** `[Proven]`
Control text reaches the log with no neutralisation. The live 12:15 log contains a caption whose
second physical line begins at column 0, typographically indistinguishable from a line the script
emitted itself. Four cells in `control-map.csv` contain newlines.

### Efficiency — reported and carried, NOT gating

Goal class is functionality/safety, so efficiency Warnings do not gate the verdict and are excluded
from the `Warning=11` count above.

**E18 — no aggregate deadline on the enumeration.** `[High]` `swd_msg.ps1`
181 × 2 = **362** blocking round trips, worst case 181 × 2 × 2000 ms = **724 s ≈ 12 min** — the same
order as the scan it exists to observe. `SMTO_ABORTIFHUNG` does not help a window that is slow but
still pumping.

**E19 — the diagnostic enumerates twice.** `[High]` `swd_diagnose.ps1`
A second full 362-message enumeration answers a membership question the first already answered,
doubling the worst case. An `@(...)` wrapper additionally defeats `Select-Object -First 1`'s
short-circuit.

> ### ⚠️ Anti-gaming note, carried from the efficiency pass
> An enumeration fix — a `-NoText` fast path, or a shorter per-message timeout — **changes what is
> returned** under some conditions. It must therefore ship *paired* with C6's timeout accounting. A
> faster enumeration that silently returns less text is the precision-cut trap in a new costume: the
> same defect class as the Week 02.1 float64 → float32 "optimisation" that was faster only because it
> computed something different.

---

## Suggestion

| # | Finding |
|---|---|
| S20 | `[Proven]` pipe-delimited internal protocol breaks on a `|` in a class name (8 fields → coercion throws) |
| S21 | `[Proven]` cursor moved to (1,0) and never restored when `GetCursorPos` fails |
| S22 | `[High]` `GetWindowRect` return discarded, so a failed rect reads as `0,0,0,0`; `GetClassName` truncates silently at 256 |
| S23 | `[High]` `SetLastError=true` declared but never read — discarding `ERROR_ACCESS_DENIED`, the single most useful datum a UIPI-filtered call can report |
| S24 | `[High]` **no Pester tests exist.** A pure-function suite (`ConvertTo-Kmh`, the split parser, the `Ok` predicate, `Format-Integrity`, the handle predicate) is writable with SWD closed |
| S25 | `[High]` the diagnostic logs `BENMOORS\moors` when `$elev` and the integrity SID already answer that section |
| S26 | `[High]` the inline C# type was named `W` in the global namespace behind an `if (-not ('W' -as [type]))` guard, so a foreign `W` binds silently |
| S27 | `[High]` CSV formula injection: a leading `=` is quoted but not neutralised (zero occurrences in the 181 live rows) |
| S28 | `[High]` UIA `FindAll` with no `CacheRequest`, one cross-process property fetch per element |
| S29 | `[High]` `Get-SwdProcess` snapshots the whole process table on every primitive call |
| S30 | `[High]` fixed 250 ms sleep instead of poll-until-condition — the **reliability** half is the point (a false `Ok=$false` under load) |
| S31 | `[High]` full-window `32bppArgb` bitmap ≈ **23.6 MiB** per capture, no region or scale option |
| S32 | `[Proven]` stale figures in [`BUILD-NOTES.md`](BUILD-NOTES.md) — **corrected 2026-08-27**, see below |

---

## What SQA rebutted — worth keeping, so it is not re-raised

- `Save-SwdWindowImage`'s GDI/GDI+ release paths are **clean on every path including exceptions**
  (traced independently by two specialists).
- `IntegritySid`'s five native exits leak nothing and double-free nothing.
- **`PrintWindow` cannot fall back to a screen grab** — `GetDesktopWindow` is not even declared,
  `CopyFromScreen` appears only in comments, and `0x00000002` was confirmed as `PW_RENDERFULLCONTENT`
  against this machine's own `WinUser.h:4609`.
- Format-string abuse, `$(...)` re-evaluation, and regex backtracking via control text were all
  measured and refuted.
- `BlockInput($false)` cannot release another process's block, and `BlockInput($true)` appears nowhere.
- `Set-SwdNumeric`'s clamping contract verified end to end; the "half-committed control" hypothesis
  was **refuted**.
- The two items flagged as deliberate in [`BUILD-NOTES.md`](BUILD-NOTES.md) both stand: `-Activate` defaulting off is
  right (C4 says the *mechanism* is broken, a different claim), and `Get-SwdText` returning `$null`
  on timeout is the right contract (C6 says no *consumer* tests for it).

## Open questions SQA could not close

- **[Needs-info]** Whether SWD's toggles use `FlatStyle=System`. That would make `BM_GETCHECK` work
  and soften C2 to a Warning. The class name is `WindowsForms10.BUTTON.*` either way, so the control
  map cannot answer it.
- **[Needs-info]** Whether `BM_CLICK`/`WM_SETTEXT` actually cross the UIPI boundary from an elevated
  shell into SWD. All harness proofs are in-process. Running the click probe from **both** shells is
  still the one experiment that converts the headless claim from inference to evidence.
- **[Needs-info]** Whether SWD renders numerics in French — decides whether W10 is latent or live.
- **[Needs-info]** The timeout regimes are derived from documented `SMTO_ABORTIFHUNG` semantics, not
  observation. One measurement settles it: during a real scan, call `Get-SwdControl` once and record
  elapsed time plus the count of `$null` texts.
- **`181` is a floor, not a constant.** The scan panel is built on demand, so every worst-case figure
  scales linearly and must be re-derived once the scanner is open.

## Closed since the report

- **ACL escalation does NOT fire.** SQA asked for `icacls` on `phase2\`: if any `BUILTIN\Users` or
  `Everyone` write ACE existed, a Medium-integrity replacement of `swd_msg.ps1` before an elevated
  run would be a genuine privilege escalation and C-grade. Measured — only
  `NT AUTHORITY\SYSTEM`, `BUILTIN\Administrators` and `BENMOORS\moors` hold `(F)`. Finding stays put.
- **S32, corrected.** Re-measured 2026-08-27 after the rewrite: `swd_msg.ps1` **2108 tokens /
  496 lines**, `swd_diagnose.ps1` **1655 / 331**, `swd_ui.ps1` **626 / 102**. InjectionHunter sites
  are `swd_msg.ps1:29`, `swd_diagnose.ps1:192`, `swd_diagnose.ps1:204` (plus `swd_ui.ps1:12`, out of
  scope). The figures in [`BUILD-NOTES.md`](BUILD-NOTES.md) § 4 were measured before later edits and were stale by the
  time they were read.
