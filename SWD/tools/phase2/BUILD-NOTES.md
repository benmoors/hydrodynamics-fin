# 🛠️ Phase 2 automation — build notes

Production record for every script in `SWD/tools/phase2/`, written so a later SQA pass has the
reasoning, not just the result. Working document, kept in the same register as `SWD/TODO.md` — no
prose pass applied, deliberately, because it is an audit record rather than a deliverable.

**Started 2026-08-27.** Plan: `~/.claude/plans/coudl-you-open-up-expressive-rose.md`.

---

## ⚠️ Read this before reviewing anything below

**Status 2026-08-28: the original 3-round loop closed at `Critical=0 | Warning=7 | Suggestion=11`.
A modal-dialog layer was then added and put through its own SQA round** (`C=3 W=6 S=8` -> fixed ->
independent verification in progress). **Pester 225/225**, revert challenge 24/24 on a hand-authored
set. The code runs; the dialog layer has still **never executed against SWD**.

*(This box previously said the pair did not run, because a `W` → `SwdWin` rename sat unpropagated for
about an hour on 2026-08-27. Round 1 reconciled all 19 sites. `[W]::` now appears nowhere in the
code — only, until this edit, in the documents warning about it. Third occurrence of the
stale-document class the loop kept raising as S32.)*

**Sections A–E of the diagnostic have run against SWD; F has not.** Nothing has yet sent a
state-changing message — `Invoke-SwdButton` and `Set-SwdNumeric` remain completely unexercised. The
original version of this line read *"not one line of this code has run against SWD"*, which was true
when written and stopped being true at 12:11.

That distinction matters here more than usual, because **the whole reason Phase 2 stalled was
automation that reported success while doing nothing.** Treat every "should" in this document as
unverified until a run says otherwise.

---

## 📂 1. What was produced

| File | Lines | Role | New? |
|---|---:|---|---|
| `swd_msg.ps1` | 1129 | Message layer — drives SWD by `BM_CLICK`/`WM_SETTEXT` to control handles. The headless route | **new** |
| `swd_diagnose.ps1` | 662 | Step 0 — settles which blocker diagnosis is right, and whether unfocused clicking works | **new** |
| `swd_ui.ps1` | 102 | Pre-existing cursor/UIA layer, kept as fallback | untouched |

`swd_ui.ps1` was **not modified**. An append was attempted and failed at the shell level before
writing anything; the file is byte-identical to its 09:05 state (verified: 102 lines, original
`tail`). The message layer went into its own file instead, which also means the SQA pass only has to
cover new code.

---

## 📂 2. The decisions, and why

Each of these is a place where a different choice was available. They are the things worth arguing
with during review.

### 2.1 Separate file rather than extending `swd_ui.ps1`

The plan said extend it. Separate file was chosen instead, for three reasons: the message layer is
now the *primary* route and the cursor layer the fallback, so they are different concerns; the
existing file works and is the documented fallback, so the smallest safe diff to it is none; and it
keeps the SQA surface to new code only.

### 2.2 `SendMessageTimeout`, never bare `SendMessage`

A plain `SendMessage` to a window that is mid-scan blocks the **caller** until the window pumps
messages again. With a 12–21 minute scan running, that is a hang, not a delay. Every read goes
through `SendMessageTimeout` with `SMTO_ABORTIFHUNG`.

### 2.3 `-Post` for long operations

`BM_CLICK` **sent** returns only when the click handler returns. Sent to the scan button, that
blocks for the entire scan. `Invoke-SwdButton -Post` uses `PostMessage`, so the scan is started and
then observed by polling. Short, instant clicks can use the sent form and get a real return value.

### 2.4 `-Activate` defaults to **off**, and is a measured question

Microsoft documents that `BM_CLICK` *"might fail"* when the button is in a dialog box that is not
active, and advises `SetActiveWindow` first. Activation is exactly what would destroy the headless
property, so it is not enabled speculatively. `swd_diagnose.ps1 -ClickProbe` exists solely to settle
this on a harmless control before the scan path depends on it. The returned object records which
form was used, so a log can never be ambiguous about whether a click was activated.

**This is the single highest-value thing for SQA to attack.** If the probe is wrong, the whole
headless claim is wrong.

### 2.5 `Set-SwdNumeric` reads back and asserts

A WinForms `NumericUpDown` is an `EDIT` plus an `msctls_updown32` buddy. `WM_SETTEXT` on the `EDIT`
does **not** become the control's `.Value` until the control validates. So the function writes,
sends Enter and `WM_KILLFOCUS` to force validation, then reads back with `WM_GETTEXT` and compares
numerically.

`Ok` is true only if the readback parses and equals the request within tolerance. A control that
clamps 40 to its maximum of 30 returns `Ok=$false` with `After=30` — the honest answer, not a
failure to retry. **A write that is not read back is the same silent success that wasted the first
attempt at this.**

### 2.6 `PrintWindow`, not `CopyFromScreen`

`swd_ui.ps1`'s `Shoot` uses `Graphics.CopyFromScreen`, which grabs whatever is on the display. With
SWD minimised — the entire point of the headless route — that captures **the user's own screen**:
useless as evidence and a privacy problem. `Save-SwdWindowImage` uses `PrintWindow` with
`PW_RENDERFULLCONTENT` against SWD's own HWND: correct when unfocused, and it captures nothing
belonging to anyone else. It warns rather than silently saving a black PNG when `PrintWindow` fails.

### 2.7 `ConvertTo-Kmh` exists because of a unit trap

The controls are `NumericUpDownScanSpeed{1,2,3}kmh` — **kilometres per hour** — while every number
in this project is m/s. Typing `10` into a km/h box asks for 2.78 m/s, not 10, and the resulting
scan would look plausible and be wrong. 20 m/s = 72 km/h; the 10 m/s verification target = 36 km/h.

### 2.8 Windows PowerShell 5.1 compatibility is a requirement, not a preference

Section D of the diagnostic loads `UIAutomationClient`, a .NET Framework assembly. A PowerShell 7
ternary was written and then removed for this reason. Both scripts are parse-checked under **both**
hosts (§ 4).

### 2.9 The diagnostic refuses to act on its own

It clicks nothing unless given an explicit `-ClickProbe <handle>`, and it validates that the handle
is actually a child window of SWD before using it. The cursor test in section C moves the pointer
one pixel and restores it, and can be skipped with `-SkipCursorTest` — a skip is logged as
**"NOT CHECKED, not as passing"**, which is the same discipline the prelearn preflight uses.

---

## 📂 3. What the diagnostic is designed to distinguish

Two diagnoses of the original blocker are on record and they contradict each other:

| Source | Claim | Fix implied |
|---|---|---|
| `docs/phase2-hydroscan.md` § 5 | Stuck `BlockInput` held by a screen-control tool. Says *"same integrity level as SWD, so UIPI is not the cause"* | Quit that tool |
| WP3 plan § 3a | UIPI — SWD's manifest asks `highestAvailable`, so it runs High-integrity and filters messages from a Medium client | Run automation elevated |

Section B answers it directly by comparing integrity SIDs, and treats *"the token could not be
opened"* as itself the answer. Section C independently re-tests the input block. **They can both be
true**, which is why neither is assumed.

Planning-time evidence favouring UIPI, none of it conclusive on its own:

- `BENMOORS\moors` is in `BUILTIN\Administrators`, currently *"used for deny only"* — a UAC split
  token, so `highestAvailable` **will** elevate.
- Microsoft: *"UIPI implements restrictions… that prevent lower-privilege applications from sending
  messages or installing hooks in higher-privilege processes."* The documented bypass, `uiAccess`,
  needs a signed binary in a protected folder.
- 98 elements all bare `Pane` is the documented signature of a UIA client that cannot reach the
  target's in-process provider.
- No screen-control tool was resident when checked against a 25-name list.

**Counter-evidence, recorded rather than buried:** `SetCursorPos` returning `False` is *not*
explained by UIPI. If section C reproduces that, the original diagnosis is at least partly right.

---

## 📂 4. Verification actually performed

Everything below was run on 2026-08-27 and the results are copied, not remembered.

| Check | Tool | Result |
|---|---|---|
| Parse, PowerShell 7.6.5 | `[Parser]::ParseFile` | All files parse clean under pwsh 7.6.5 **and** Windows PowerShell 5.1. **Token and line counts are deliberately not recorded here** — they went stale twice in one day (finding S32, raised in both SQA rounds) because every fix moves them. Measure them when you need them. |
| Parse, Windows PowerShell 5.1 | same, under `powershell.exe` | both new files OK |
| Lint | PSScriptAnalyzer 1.25.0, Error+Warning | **0 findings in new code** after fixes |
| Injection | InjectionHunter 1.0.0 | 3 findings, all assessed below |
| `swd_ui.ps1` unchanged | `wc -l`, `tail`, mtime | 102 lines, 09:05 timestamp, content intact |

### Fixed during the build

| Finding | Action |
|---|---|
| `PSUseSingularNouns` on `Get-SwdControls` | Renamed `Get-SwdControl` (+2 call sites). PowerShell convention is singular even for collection-returning cmdlets |
| `PSUseShouldProcessForStateChangingFunctions` on `Set-SwdNumeric` | Added `SupportsShouldProcess`. Not box-ticking — `-WhatIf` on a function that writes into a live GUI is genuinely useful when rehearsing a scan configuration |
| StrictMode hazard | `$ok` in `Save-SwdWindowImage` was read after a `try` block that could throw before assigning it. Initialised to `$false` |
| PowerShell 7-only ternary | Removed; would have broken the 5.1 run that section D needs |

### Accepted, with reasons — these are the arguable ones

| Finding | Where | Assessment |
|---|---|---|
| `InjectionRisk.AddType` | `swd_msg.ps1:29`, `swd_diagnose.ps1:192` | The rule fires on *any* `Add-Type`; it cannot tell a literal from a constructed one. `swd_diagnose.ps1:164` passes literal assembly names. **Hardened anyway:** the C# here-string was switched from `@"…"@` to `@'…'@`, so it no longer interpolates. It contains no `$` or backtick today (checked), so behaviour is unchanged — the point is that a later edit can no longer quietly introduce one |
| `InjectionRisk.UnsafeEscaping` | `swd_diagnose.ps1:204` | `-replace '^ControlType\.', ''` — the *pattern* is a literal; the *input* is a UIA `ProgrammaticName` from the target app. Used only as a hashtable key and printed. No eval anywhere. Assessed as a false positive, but note the input is technically target-controlled |
| `PSUseApprovedVerbs` on `Focus-Swd` | `swd_ui.ps1:65` | **Pre-existing, not mine.** In the fallback file. Left alone rather than churn working code |

### Found by running, 2026-08-27 12:02

**A `[CmdletBinding()]` trap in Windows PowerShell 5.1.** With the attribute present, `$PSScriptRoot`
is **empty inside `param()` default values**; remove it and the identical default works. Isolated by
bisecting a minimal repro — the comment-based help block and the relative-vs-absolute `-File` path
were both ruled out first. `swd_diagnose.ps1` died on its own first line before any body code ran.
Fixed by resolving `$ScriptDir` after the param block, with a `$MyInvocation` fallback.

The same class of bug, different mechanism, was fixed in `swd_msg.ps1`: inside a **function**,
`$PSScriptRoot` resolves at **call** time and points at the *calling* script. `Save-SwdWindowImage`
would have written its PNGs beside whoever dot-sourced it. Now captured at load time as
`$script:SwdMsgRoot`.

**A correction to `docs/phase2-hydroscan.md` § 5.** That document's central evidence for a stuck
input block was: *"`BlockInput(false)` returns `False` with `ERROR_ACCESS_DENIED (5)`… means another
process holds an input block and only that process can release it."*

First run of section C, non-elevated, SWD closed:

| Measurement | Result |
|---|---|
| `SetCursorPos` | `True`, lastError 0 |
| Cursor actually landed | **`True`** — asked (1026,730), got (1026,730) |
| `BlockInput(false)` | `False`, **lastError 5** |

So error 5 appears *while the cursor moves freely*. It is what a non-elevated caller gets, not proof
of a held block. The § 5 inference does not hold. **Still to check on the elevated run:** whether
`BlockInput(false)` then returns `True`, which would confirm it is purely a privilege artefact.

Note this does **not** establish that there was no block back on 26 August — `SetCursorPos` returning
`False` then is unexplained and was real. It establishes that one of the two pieces of evidence for
it was worthless, and that nothing is blocking input now.

### The UIPI question, settled by running - 2026-08-27 12:11 and 12:13

One variable changed between the two runs: elevation. Same SWD process (pid 42488) throughout.

| | Non-elevated shell | Elevated shell |
|---|---|---|
| This shell | Medium `S-1-16-8192` | High `S-1-16-12288` |
| SWD | **UNREADABLE** (token access denied) | High `S-1-16-12288` |
| UIA descendants | **98, every one a bare `Pane`** | **131, named**: 15 Button, 8 MenuItem, 16 Text, 6 Group, 2 ComboBox, 3 Separator, ToolBar, StatusBar, MenuBar, Thumb, 77 Pane |
| `BlockInput(false)` | `False`, lastError **5** | `False`, lastError **0** |

**UIPI was the blocker.** `docs/phase2-hydroscan.md` para 5 is wrong on both of its load-bearing
claims: *"same integrity level as SWD, so UIPI is not the cause"* - they were not the same level -
and `ERROR_ACCESS_DENIED` from `BlockInput(false)` as proof of a held block, when the elevated run
returns `False` with **no error at all** and the cursor moves freely in both. That call returning
`False` simply means input was never blocked.

**Reads cross the integrity boundary; that was not expected.** `EnumChildWindows` plus `WM_GETTEXT`
returned real text for all 181 controls from the *Medium* shell. UIPI filters state-changing
messages, so the sharp prediction is that `BM_CLICK` and `WM_SETTEXT` fail unelevated and succeed
elevated. **Running the click probe from both shells would demonstrate that in one pair of
measurements** - worth doing, since it converts the headless claim from inference to evidence.

**181 child windows, not the plan's 165.** Not a contradiction: the count depends on what is open.

**The scan parameter controls do not exist yet.** One `msctls_updown32` in the entire application,
and nothing whose text mentions drift or speed. The panel is built on demand - the app itself says
*"No HydroScan for this board... Use the Scaner tool"*. So `NumericUpDown_scan_drift_*` and
`NumericUpDownScanSpeed*kmh` are unresolvable until the scanner is opened, and **the control map is
inherently two-stage**. The scan driver cannot be written against the current map.

Located and confirmed enabled: **`Hydrodynamics Scanner`, handle `19726830`**.

Still open: the title bar reads `<no Wave>`, so whether a wave is a precondition for scanning is
untouched.

### Two more defects, found by running - 2026-08-27 12:13

Both are the same species as the bug this project exists to avoid: output that looks fine and is not.

1. **The log was UTF-16LE with a BOM.** `Tee-Object` under Windows PowerShell 5.1 writes Unicode;
   first bytes measured `ff fe 53 00`. `CLAUDE.md` para 5 already records that a BOM breaks the
   Python readers downstream, and the QA protocol records *"never parse an agent report out of a
   PowerShell pipe"* for this exact reason. Replaced with `[IO.File]::AppendAllText` and a
   `UTF8Encoding($false)`. Re-measured: `53 57 44 20` - UTF-8, no BOM.
2. **Section A contradicted section B in the same report.** A read the integrity level from
   `WindowsIdentity.Groups`, which printed `Medium-or-lower` on a run where B's token query said
   `High`. Groups does not reliably carry the integrity SID. Section A now calls the same token
   query; both agree, verified on a fresh non-elevated run (`Medium [S-1-16-8192]`).

A third, cosmetic: `Write-Host` tripped `PSAvoidUsingWriteHost`; swapped for `Out-Host`, same effect
for a console diagnostic that is never piped.

### Not verified, and this is the honest list

- **`Invoke-SwdButton` and `Set-SwdNumeric` are still completely unexercised.** Sections A-E have
  run against SWD; F has not. Nothing has yet sent a state-changing message.
- ~~The **165 child windows** figure comes from the plan's narrative~~ - measured: **181**.
- Whether `BM_CLICK` lands unfocused — the entire headless premise — is **unmeasured**. Section F exists to measure it.
- Whether `WM_SETTEXT` + Enter + `WM_KILLFOCUS` actually commits a `NumericUpDown` on this build.
- Whether `PrintWindow` returns usable pixels for a DX11-composited child window, minimised or not.
- ~~No Pester tests.~~ **Superseded: 180 tests across two suites** — `tests/swd_msg.Tests.ps1` (162)
  and `tests/swd_diagnose.Tests.ps1` (18, end-to-end with SWD closed). Pin Pester to 6.1.0.
  Caveat worth keeping: an independent 15-mutant study found **5 bite, 10 survive**, so the green is
  real but does not cover five of round 3's own changes. See the ledger.

---

## 📂 5. Suggested SQA scope

`CLAUDE.md` § 4 requires an SQA pass over any new `.ps1` that touches SWD **before it runs against
the real installation**. This is that code.

**In scope:** `swd_msg.ps1`, `swd_diagnose.ps1`.
**Out of scope:** `swd_ui.ps1` (unchanged), `swd_extract.ps1` (already three rounds + independent verification).

Worth pointing the specialists at:

- **`sqa-functional`** — the readback/assert logic in `Set-SwdNumeric` (clamping, locale decimal
  separators, `null` vs `""` from `GetText`, non-numeric text); the handle-validation in section F;
  behaviour when SWD exits mid-run.
- **`sqa-security`** — the `Add-Type` and `-replace` findings above; whether target-controlled window
  text reaching a log or a CSV can do harm; that `Save-SwdWindowImage` cannot capture anything
  outside SWD's own window.
- **`sqa-efficiency`** — `Get-SwdControl` sends two messages per control across ~165 controls, and
  section F calls it a second time. Timeout budget under a busy app is the real question.
- **`sqa-embedded`** is **not** applicable — no firmware, no registers, no ISRs.

Two things that should **not** be treated as defects: the deliberate absence of `-Activate` by
default (§ 2.4), and `Get-SwdText` returning `$null` on timeout as distinct from `""` on empty text.

### Locale note worth checking early

`SWD/data`'s French-locale trap (`fyn_profile_data_base.xml` uses comma decimal separators) has a
sibling here: `[double]::TryParse` in `Set-SwdNumeric` uses **current culture**. If SWD's numeric
boxes render `10,5` under a French UI, the comparison silently misreads. Unverified either way — the
machine is en-AU, but the app is French in origin.

---

## 📂 6. Running it

```powershell
# normal shell first - establishes the baseline
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "SWD\tools\phase2\swd_diagnose.ps1"

# then elevated - the difference between the two runs IS the answer
# RunAs starts in a different working directory, so -File must be absolute.
$diag = Join-Path $PWD 'SWD\tools\phase2\swd_diagnose.ps1'
Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',
  $diag

# then, after reading control-map.csv and choosing a HARMLESS control:
... -File '<path>\swd_diagnose.ps1' -ClickProbe <handle>
```

Outputs: `logs\<timestamp>-diagnose.log` and `control-map.csv`, both beside the scripts.

SWD must be launched by hand first — **watch for a UAC prompt, because that observation alone
decides the diagnosis** and no script can see it.
