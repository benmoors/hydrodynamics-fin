# ▶️ RESUME HERE — Phase 2 automation

Entry point for a session with no memory of this work. Updated 2026-08-28 at QA-loop close.

---

## ✅ The code runs. The QA loop is closed.

A 3-round SQA loop finished at the cap with **`Critical=0 | Warning=7 | Suggestion=11`**.

*(An earlier version of this file said the code was BROKEN and must not be run. That was true for
about an hour on 2026-08-27, while a type rename sat unpropagated. It is no longer true.)*

| File | Lines | State |
|---|---:|---|
| `swd_msg.ps1` | 1129 | Message primitives. 3 fix rounds, independently verified each time |
| `swd_diagnose.ps1` | 662 | Read-only A–F diagnostic |
| `tests/swd_msg.Tests.ps1` | 1030 | 162 tests |
| `tests/swd_diagnose.Tests.ps1` | 293 | 18 tests, end-to-end with SWD closed |
| `swd_ui.ps1` | 102 | Untouched cursor/UIA fallback. Out of scope throughout |

**Pester 180/180** under 6.1.0 (pin it — a bundled 3.4.0 coexists and cannot run 6.x syntax).
PSScriptAnalyzer clean on all four files under Windows PowerShell 5.1 **and** pwsh 7.6.5.

---

## 🚦 What you may and may not run — the verifier's judgement, not the author's

**✅ Run the read-only diagnostic.** Unelevated first, then elevated; the pair is the evidence.
The path guard was proven against 34 adversarial spellings, both output paths resolve before anything
is created, and three rounds of tests that deliberately *attempt* the forbidden write left the
install intact.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "SWD\tools\phase2\swd_diagnose.ps1"
# RunAs starts in a different working directory, so -File must be absolute.
$diag = Join-Path $PWD 'SWD\tools\phase2\swd_diagnose.ps1'
Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass',
  '-File',$diag
```

**✅ Run ONE `-ClickProbe` on a control you choose — under four conditions.**

1. Take the handle from a **freshly generated** `control-map.csv`. Every handle in every document
   here is stale; SWD has restarted since.
2. Pick a control whose **caption changes**. Never a checkbox — `BM_GETCHECK` was measured blind on
   `FlatStyle=Standard`, which is what SWD is built from.
3. ~~Never the scan button.~~ **Superseded 2026-08-28, deliberately and with the user's explicit
   sign-off.** Probing it is what proved the mechanism on the real application. It raises a modal
   confirmation and does NOT start a scan by itself. Still not a casual target.
4. **Do not trust the "THE CLICK LANDED WITHOUT FOCUS" line.** See Warning 1 below. Cross-check it
   by hand against the `foreground now:` and `foreground moved during the window:` handles the log
   already prints.

**❌ Do NOT write the scan driver yet**, and not mainly because of the Warnings.
`Invoke-SwdButton` and `Set-SwdNumeric` have **never executed against SWD** — every "live" proof
drives a throwaway WinForms form that answers messages a High-integrity, mid-scan application may
refuse. And the scan parameter controls do not exist until the scanner panel is open, so the control
map is two-stage and the driver cannot be written against the current one.

---

## ⚠️ The seven Warnings, and the one that matters for the next step

**1. `swd_diagnose.ps1:493,494,556` — the unfocused verdict can be wrong, in the unsafe direction.**
`$heldFocus` compares handle identity against a `MainWindowHandle` cached once at `:185` and never
refreshed. If SWD holds the foreground through a **second top-level window**, the run prints
"THE CLICK LANDED WITHOUT FOCUS" for a click that was not unfocused. Reproduced on a two-form
cross-process harness. `OwnerPid` already exists at `swd_msg.ps1:177` and is used correctly at `:703`
— it is simply not used here. **This is the project's load-bearing claim, so hand-check the logged
foreground handles until it is fixed.**

**2–7, all test-adequacy rather than behaviour:** the `$fgAfter` fix has no coverage (two reverts
survive 18/18); the library-8.3 test passes for the wrong reason (both fixture paths exist, so the
lexical guard alone refuses them and the canonical layer is never decisive — one-token fix is a
non-existent leaf); the surrogate-pair branch has zero behavioural coverage; `Invoke-Diagnose` merges
stderr and never reads `$LASTEXITCODE`, so **3 of 18 tests fail spuriously under a caller with
`$ErrorActionPreference='Stop'`** — and they are the § 4 refusal tests; those same refusal tests
detect a guard regression only *after* the write; and W4's fix has no detector, with the "needs a
timing race" rationale refuted (the suite already rewrites one seam by string replacement, so a
call-index sentinel would be deterministic).

**All remaining risk is in the "reports a conclusion it did not measure" class, not the "damages the
installation" class.** Given this project exists because automation once reported success while doing
nothing, that is the class to keep watching.

---

## Next steps

| # | Step | State |
|---|---|---|
| 1–4 | Diagnosis | ✅ **UIPI confirmed.** Fix is to run elevated |
| 5–5b | 3-round SQA loop | ✅ Closed at cap, `C=0 W=7 S=11` |
| 6 | `BM_CLICK` probe | 🟡 **half done.** Elevated click LANDED on the real app; unelevated refused at `lastError=5`. **Unfocused case still unproven** — SWD had focus |
| 7 | Scan driver | ⬜ Blocked — needs (a) a second control map with the scanner panel open, and
  (b) **modal-dialog handling**: the scan button raises a confirmation the driver must dismiss itself.
  A modal is a separate top-level window that `Get-SwdControl` cannot see. See [`SWD/TODO.md`](../../TODO.md). |
| 8 | Verification scan | ⬜ 1 unscanned board, 3 drift angles, **36 km/h** |
| 9 | Re-approve + re-extract | ⬜ Recovered speed must read 10.000, not 20.000 |
| 10 | Radius question; close out | ⬜ |

### Step 6 result, measured live 2026-08-28 on pid 61624

Same control, same session, same unfocused state — one variable changed:

| | Unelevated | Elevated |
|---|---|---|
| `sent` | **False** | **True** |
| `lastError` | **5** (`ERROR_ACCESS_DENIED`) | **0** |
| Reads | 165/165, 0 timed out | 165/165, 0 timed out |

**UIPI filters state-changing messages and passes reads.** Elevation is the fix, demonstrated on the
real application rather than a harness.

A later elevated click on `Hydrodynamics Scanner` **landed** — it raised the modal confirmation and,
once accepted, started a real scan. That send reported `lastError=1460` (`ERROR_TIMEOUT`) because the
modal blocked SWD's message pump; the click had succeeded and only the acknowledgement could not
**Read `1460` on a sent `BM_CLICK` as AMBIGUOUS - the send did not complete, and that happens BOTH
when the click landed and opened a modal AND when the target's pump was blocked and it never landed.**
Measured by SQA 2026-08-28, reproduced twice: two sends to a control whose UI thread was blocked both
returned `1460`, and the target's own click counter read **0** afterwards - neither click landed. An
earlier version of this document asserted `1460` meant "probably landed". That was wrong, and
asserting it was the same defect - a conclusion reported without observing it - that this project
exists to prevent. The only way to tell is to observe: poll for a dialog, and check the target's state.

**STILL UNPROVEN: the unfocused case.** SWD held focus for that click (the operator had clicked it to
watch), so "the scan can run while the machine is used" remains an inference. One more probe, SWD
unfocused, settles it.

### What was settled, so it is not re-derived

- **SWD runs elevated at High integrity** (`S-1-16-12288`); a Medium shell cannot open its token.
- **UIPI was the blocker.** UIA from Medium returns 98 bare `Pane`s, from elevated 131 named
  elements. `docs/phase2-hydroscan.md` § 5 has been rewritten; it used to claim the opposite.
- **There is no input block.** `SetCursorPos` succeeds and the cursor lands, in both runs.
  `BlockInput(false)` returning `False` carries no information either way.
- **The scan parameter controls do not exist until the scanner panel opens** — one `msctls_updown32`
  in the whole application. The control map is two-stage.
- **The speed boxes are km/h; this project is m/s.** 20 m/s = 72 km/h, 10 m/s = 36 km/h. Typing `10`
  asks for 2.78 m/s and produces a plausible, wrong scan. `ConvertTo-Kmh` exists for this.
- **Directory ACLs on `phase2\` are clean** — `SYSTEM` / `Administrators` / `moors` only.

## Environment facts worth not rediscovering

- **Windows PowerShell 5.1 at runtime**, not `pwsh` 7 — section D loads `UIAutomationClient`, a .NET
  Framework assembly. All files must also *parse* under 7.
- **`[CmdletBinding()]` empties `$PSScriptRoot` inside `param()` defaults on 5.1.** `$ScriptDir` is
  resolved after the param block because of it.
- **`$PSScriptRoot` inside a function resolves at CALL time**, pointing at the calling script — hence
  `$script:SwdMsgRoot`, captured at load.
- **`New-Item` has no `-LiteralPath`** in either host. This crashed the diagnostic before section A
  on any first run into a non-existent log directory, and hid for two rounds because every smoke test
  pre-created one. Use `[IO.Directory]::CreateDirectory`.
- **`Tee-Object`/`Out-File` write UTF-16LE+BOM on 5.1**; `Export-Csv -Encoding UTF8` writes a UTF-8
  BOM. Use `[IO.File]::AppendAllText`/`WriteAllLines` with `UTF8Encoding($false)`.
- **Path canonicalisation has bitten this project three times.** `GetFullPath` expands 8.3 but not
  `~`; `GetUnresolvedProviderPathFromPSPath` expands `~` but not 8.3. Only
  `GetFinalPathNameByHandleW` expands 8.3 *and* follows junctions, symlinks and `subst`.
  `swd_extract.ps1:189-260` had already solved this; round 3 ported it rather than inventing a
  fourth resolver. **Do not write a fifth.**
- **A heredoc chained after `cd &&` fails in this project's Bash tool.** Use absolute paths.
- Pin Pester to **6.1.0**. PSScriptAnalyzer 1.25.0, InjectionHunter 1.0.0 installed.

## Standing safety rules — [`CLAUDE.md`](../../../CLAUDE.md) § 4

Never write inside `C:\Program Files\ShaperWaveDynamics\`. Never modify a file in `biblio\` in place —
deserialise a **copy**. Note Documents is redirected to
`%OneDrive%\Documents\`. Never construct `Form_shaper` headlessly.
`BinaryFormatter` needs Windows PowerShell 5.1. After any scan session re-approve with
`-TrustCurrentLibrary`, and **never** use `-AllowUntrustedFiles` to dodge the gate. Do not accept
SWD's advertised 1.1.0.6 upgrade — it would invalidate the trust manifest and possibly the file format.

## Where everything is

| | |
|---|---|
| Active plan | `~/.claude/plans/coudl-you-open-up-expressive-rose.md` |
| Deferred (WP1 paper data, WP2 metrics doc) | `~/.claude/plans/do-some-research-to-atomic-sky.md` |
| Live checklist + run history | [`SWD/TODO.md`](../../TODO.md) |
| Blocker diagnosis, rewritten | [`SWD/docs/phase2-hydroscan.md`](../../docs/phase2-hydroscan.md) |
| Production record | [`SWD/tools/phase2/BUILD-NOTES.md`](BUILD-NOTES.md) |
| Original 32 findings, verbatim | [`SWD/tools/phase2/SQA-FINDINGS.md`](SQA-FINDINGS.md) |
| Loop staging, 5 snapshots | `~/.claude/qa-backups/20260827-193428-swd-phase2/` |
| Ledger | `~/.claude/qa-history/swd-phase2.md` |

**SWD is not running.** Every handle recorded in any of these documents is stale — window handles do
not survive a process restart. Relaunch, re-run the diagnostic, take handles from the fresh
`control-map.csv`.
