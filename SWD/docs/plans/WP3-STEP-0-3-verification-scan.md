# WP3 Steps 0–3 — the verification scan

> ### ⚠️ Correction, 2026-09-01 — `20.0391 m/s` is not a speed
> Decompiling `Form_shaper.actualiser_fluide()` showed SWD picks water density from a
> **4-entry lookup table** (salt `1028/1027/1025/1023` by temperature ∈ {0,10,20,30} °C),
> never a formula. `mass_flux/frontal_section` is exactly `ρ·V` and takes exactly two
> corpus-wide values, **20460.0** and **20500.0** = `1023×20.000` and `1025×20.000`.
> So the corpus is **one flow speed (20.000 m/s) at two water temperatures**, and the
> phantom second speed was `20500/1023 = 20.0391` — the 1025-density scans divided by an
> assumed 1023. Wherever this file treats 20.039 as a speed or as float noise, read it as
> a ρ = 1025 scan instead. **The conclusion that `flow ms` does nothing is unaffected and
> in fact strengthened**: the flow speed was 20.000 throughout. See `CLAUDE.md` § 5.



**Stage plan, written 2026-08-29 for execution 2026-08-30.** Standalone: everything needed is here.
Do not go looking for a predecessor document.

**Prerequisite:** none. This is the first WP3 stage.
**Unlocks:** `WP3-STEP-4-batch-driver.md`, which must not start until Step 3 passes.

---

## 1. Why this exists

`SWD/data/operating_points.csv` holds **667 rows** and all four channels the surrogate needs —
`scan_speed_ms`, `roll_rad`, `turn_radius_m`, `drag_total_n` — plus `lift_total_n` for the BJ/Ra
bridge. One column is degenerate:

> **`scan_speed_ms` has a single physical value.** 20.000 and 20.039 m/s, and the second is float
> noise around the first. Every one of the 143 existing reports ran at the same condition.

So nothing trained on this corpus can speak to speed dependence. Speed is a top-level input in
`surfing-performance-io.md` § 4.1, and the heaviest rubric item (**25 %**) is *Validation and
engineering credibility*. `turn_radius_m` is already settled as per-board metadata — constant within
13 of 13 scanned boards — so it cannot be a feature. **Speed is the one axis still recoverable by
scanning**, and that is what WP3 exists to fix.

This stage does not fix it. It proves the mechanism on one board so the 13-hour batch is not run on
an unverified parameter path.

---

## 2. What is already built, and never once attempted

`SWD/tools/phase2/swd_msg.ps1` — 1,866 lines, three SQA rounds, closed at `Critical=0`. It contains
`Invoke-SwdButton`, `Set-SwdNumeric`, `Get-SwdControl`, and the whole modal-dialog layer
(`Get-SwdDialog`, `Get-SwdDialogControl`, `Wait-SwdDialog`, `Wait-SwdDialogGone`,
`Invoke-SwdDialogButton`, `Get-SwdTransportOutcome`, `Format-SwdSendError`).

`SWD/tools/phase2/RESUME.md:54` states the position plainly:

> "`Invoke-SwdButton` and `Set-SwdNumeric` have **never executed against SWD**"

Every "live" proof to date drives a throwaway WinForms harness. **This stage is the first time any of
it is pointed at the real application.** Treat every success as unproven until observed.

---

## 3. The target board

`2003_Taylor_Knox_channel_island`

| Criterion | Value | Why it matters |
|---|---|---|
| `has_hydroscan` | **0** | Nothing can be overwritten — no `.fynrhydro` exists for it |
| Turn radius | **22.8 m** | A radius the corpus does not have (it holds 19.1, 30.1, 34.7, 45.9, 56.5, 87.3, 115.9, 312.1, 100000) |
| Mass / volume | 2.277 kg / 31.919 L | Matches no scanned board, unlike `default_shortboard_Copy_2` |
| Not a negative-radius board | — | `Jules_egg`, `blueTreck`, `hydroactive_Wake` are the only three negatives; they deserve a full 11-angle scan later, not a smoke test |

**Parameters: speed 36 km/h, drift min/max/step 0 / 20 / 10 → angles 0, 10, 20.** Three angles, all
inside the drift ≤ 20° surfing envelope; beyond that the board is broadside and drag reaches 522 kN.
Expected ~8 minutes at the measured ~163 s per angle.

> ### ⚠️ The unit trap
> **`ConvertTo-Kmh 10` → 36.** The speed boxes are `NumericUpDownScanSpeed{1,2,3}kmh` —
> **kilometres per hour** — while every number in this project is m/s. Typing `10` asks for
> 2.78 m/s and produces a plausible, wrong scan. 20 m/s = 72 km/h; the 10 m/s target = 36 km/h.
> Convert, never type.

**Why 10 m/s is a sound choice:** it is *more* surf-realistic than the 20 m/s every existing scan
used — real surfing speeds are roughly 3–10 m/s. The risk runs the other way: if the board fails to
plane at the lower speed the mass-balance speed recovery may degrade. That would itself be a finding,
and it is why this is three angles rather than a batch.

---

## 4. Step 0 — locate the scan parameter UI · read-only, unelevated, zero risk

**This is blocking, and it must happen before anything else.** Reads pass UIPI, so this sends nothing
but `WM_GETTEXT`, needs no UAC prompt, and cannot start a scan.

1. **You** open the scanner from SWD's own UI on the loaded board.
2. **Claude** enumerates: a `Get-SwdControl` re-walk of the main window, **plus**
   `Get-SwdDialog -IncludeInvisible` and `Get-SwdDialogControl` across every top-level window owned
   by the process.

### Expected outcome (b) — the panel is built inside the main window

`SWD/tools/phase2/logs/20260828-050934-diagnose.log:108-141` records these APPEARING in an
`EnumChildWindows` walk of the **main** window after the scan button was clicked:

```
12451950   APPEARED   '-' -> 'HydroScan'
1904378    APPEARED   '-' -> 'PropertyGridToolBar'
175114382  APPEARED   '-' -> 'Surfer Kg'
77401520   APPEARED   '-' -> 'Forces'
6947734    APPEARED   '-' -> 'Elements;analysis'
29950034   APPEARED   '-' -> 'Surfing situation:'
10880446   APPEARED   '-' -> 'Solver option:'
5570672    APPEARED   '-' -> 'Chart in window'
```

Those are scanner-panel controls, and they were reachable as children of the main window. So
`Get-SwdControl` should find the parameters, and the dialog layer is needed only for the confirmation.

| Fallback | Consequence |
|---|---|
| (a) a separate top-level window | the dialog layer already handles it — proceed |
| (c) neither | **you type the parameters, Claude drives only start + confirmation.** The scan still happens; the unattended batch does not, and that gets said plainly rather than worked around |

### Two corrections this stage must not re-derive

**1. `control-map-scanner-open.csv` is the Fins tab, not the scanner panel.** Content-diffed against
a live 166-control map on 2026-08-29, its extra controls are `Thruster`, `Quad`, `Twin`, `Fcs`,
`Fcs2`, `Future 1/2 (center)`, `Us Box`, `Toe angle°`, `Cant angle°`, `Fin technology`,
`Selected Fin Name:`, plus three `msctls_progress32` bars. It contains **zero** drift or speed
controls, so `SWD/TODO.md` worklist item 2 cannot be completed from it. Worse: it and
`control-map.csv` have **identical handle sets** — the same enumeration written twice, differing only
in `Rect`. `TODO.md:753`'s "241 with the scanner panel open, vs 165 closed" is wrong on both halves.

**2. Open question — does a WinForms `NumericUpDown` emit a native `msctls_updown32`?**
`BUILD-NOTES.md:86` asserts *"A WinForms `NumericUpDown` is an `EDIT` plus an `msctls_updown32`
buddy"*. The live map contains exactly **one**, and its parent is a `SysTabControl32` — a tab
spinner, not a numeric buddy.

- If `BUILD-NOTES` is right, there are **zero** NumericUpDowns instantiated and
  `docs/phase2-hydroscan.md:94-100`'s "not instantiated on startup" reasoning stands.
- If it is wrong, the composite is `Window.8` + `EDIT` + `Window.8` (three such triples exist live,
  all board-shape: input volume, swallow tail in/out), and that reasoning is unsound even though its
  conclusion may still hold.

**Step 0 settles it. Nothing downstream depends on the answer** — `Set-SwdNumeric` targets the `EDIT`
and readback-asserts either way.

---

## 5. Step 1 — the pre-scan snapshot

`SWD/TODO.md` worklist item 8, widened. Do all four.

| Capture | Destination | Why |
|---|---|---|
| `boards.csv`, `operating_points.csv`, `extract_manifest.json` | `~/.claude/qa-backups/20260827-193428-swd-phase2/pre-scan-2026-08-30/` | the data baseline |
| **the board's own `.fynbs`** (2.1 MB) | same | `default_shortboard_Copy_1`'s unexplained geometry change is unresolvable **because no pre-scan copy exists**. Do not repeat that |
| **`rapports_hydro/` entire** (590 MB) | `%USERPROFILE%\SWD-backup\20260830\` | outside the repo per `CLAUDE.md` § 4. This is what makes any later re-scan reversible |
| live geometry readback (length / volume / mass EDITs) | the run log | see below |

> ### Point of note — the live app and `boards.csv` disagree
> SWD currently shows **Board Volume: 26.8 liters** for this board, while `boards.csv` records
> `volume_shape_l = 31.919`. The `.fynbs` is untouched since **2021-04-27**, so this is not a stale
> extract. For `default_shortboard_Copy_1` the same label matched `boards.csv` exactly (35.2 against
> 35.2237), so the label does track that column. **Cause unknown. Record it before scanning.**

**Free space check:** 546 GB available against a 590 MB copy.

---

## 6. Step 2 — the scan

Eight conditions. Each exists because something went wrong without it.

1. **Elevation.** SWD runs at High integrity (`S-1-16-12288`); UIPI filters state-changing messages
   from a Medium shell. Measured on the same control, same session, same unfocused state, one
   variable changed: unelevated `sent=False lastError=5 (ERROR_ACCESS_DENIED)`, elevated
   `sent=True lastError=0`. **One UAC prompt to approve.**
2. **Every value via `Set-SwdNumeric`**, which writes, forces validation, then **reads back and
   asserts**. `Ok=$false` aborts the run. A control that clamps returns `Ok=$false` with the real
   `After` value — the honest answer, not something to retry around.
3. **Show the readback before anything starts.** `PrintWindow` returns false on SWD's DX11-composited
   window, so **screenshots are impossible** — `Save-SwdWindowImage` correctly writes nothing rather
   than a blank PNG. The controls are identified by position and plausible value, not by name. **Your
   eyes on the panel are the only independent check that exists.**
4. **Read the confirmation's real caption first**, then pass it to
   `Invoke-SwdDialogButton -ExpectLike '<that caption>'`. A bare `'*'` throws by design; `-AnyText`
   is the deliberate escape hatch and is not used here.

   > ⚠️ **The modal's text has never actually been captured.** The string `'*more than 60 mn*'` used
   > throughout the test suite traces to a **2026-08-27 in-app warning**, reused as a synthetic
   > WinForms label in a throwaway harness. It has never been matched against SWD's real dialog. The
   > best record of the real thing is a self-flagged paraphrase at `TODO.md:632` — *"a dialog reading
   > **roughly** 'HydroScan can take more than 60 mn - do you want to proceed'"*.

5. **Never trust `Sent`.** `BM_CLICK` returns zero regardless. Use `Get-SwdTransportOutcome`, then
   `Wait-SwdDialogGone`, and confirm the dialog is **actually gone** before starting the clock.

   > `lastError=1460` (`ERROR_TIMEOUT`) is **AMBIGUOUS**, not "probably landed". SQA measured it
   > twice on a control whose UI thread was blocked: both sends returned 1460 and the target's click
   > counter read **0** — neither landed. The favourable case returns the identical code. Observe the
   > outcome; never infer it from the return value.

6. **Record `Test-SwdOwnsForeground` before and after every send.** This closes `TODO.md` worklist
   item 1 **for free**: if a numeric commits while SWD does not own the foreground, that is the
   unfocused-send evidence on the real application, which has only ever been an inference. Note the
   function is three-state — `$null` means *unanswerable*, not *no*.
7. **Capture a control map with the modal open.** SWD's dialog class is unmeasured; the `#32770`
   claim was withdrawn in source (`swd_msg.ps1:1564-1570`) and is ledger suspect 20. One map settles
   whether the button-type guard does anything at all. Free while the dialog is up.
8. **Never `-WhatIf` as a rehearsal on a mutator you then run for real.** `Save-SwdWindowImage` still
   creates directories on some paths; `-WhatIf` inertness is covered by the safety-gate tests, and
   those are what this stage relies on.

> ### ⚠️ Guard weakness, carried openly
> **The Pester suite is not reproducible.** Measured across runs: 257/1, then 254/4 with *different*
> tests failing, then 236/1; the diagnose suite alone swings between 10 and 21 passes. Every failure
> is a timing-dependent assertion; none is a safety gate. **A guard that varies cannot gate
> anything** — this is open suspect 19 in the ledger. What this stage actually leans on is the 54
> safety-gate tests (`-WhatIf` inertness, `-ExpectLike` refusal, bare-`'*'` throw, ambiguity refusal,
> handle ownership), which passed **54/0 twice**.

---

## 7. Step 3 — verify by measurement, not by looking

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "SWD\tools\swd_extract.ps1" -TrustCurrentLibrary
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "SWD\tools\swd_extract.ps1"
```

**Never `-AllowUntrustedFiles`** — it disables the provenance gate for the whole run, and the
friction is the point. `BinaryFormatter` needs **Windows PowerShell 5.1**, not `pwsh` 7+.

| Assertion | Expect |
|---|---|
| New report files | `drift_0`, `drift_10`, `drift_20` under `rapports_hydro/2003_Taylor_Knox_channel_island/` |
| **Recovered `scan_speed_ms`** | **10.000, not 20.039** ← the entire point of the stage |
| Reports parsed | **146 / 146**, 0 failures (was 143) |
| Polar blocks | 1890 / 1890 |
| Operating points | ~667 + ~15 |
| Encoding | UTF-8, **no BOM**; `extract_manifest.json` present |

`extract_manifest.json` is written last as a completion sentinel — if it is missing, the CSV set is
unvouched however good it looks.

> ### The measurement that makes this worth doing
> The extractor recovers speed independently, from the planing mass balance `ṁ = ρAV`. If 36 km/h was
> set and the recovered value reads **10.000**, then in one run: the parameter path works, the scan
> honoured it, the extractor's speed recovery is validated against a **second value for the first
> time**, and the corpus finally has two physical speeds.
>
> **If it still reads ~20, the parameter path silently did nothing and Steps 4–7 do not start.**

**Also record the per-angle wall time at 10 m/s.** The ~163 s figure was measured at 20 m/s and
re-bases the batch estimate; the solver may not cost the same at a different speed.

---

## 8. On completion

- Update `SWD/TODO.md` — worklist items 1 and 8 closed, item 2's premise refuted, new cost model
- Update the status row in `CLAUDE.md` § 9
- Ledger entry in `~/.claude/qa-history/swd-phase2.md` per its § 8 append protocol
- Then, and only then, `WP3-STEP-4-batch-driver.md`

---

## 9. Standing constraints — `CLAUDE.md` § 4, quoted not referenced

- **Never write inside `C:\Program Files\ShaperWaveDynamics\`.** Read-only, always.
- **Never modify a file in the SWD library in place** (`%OneDrive%\Documents\ShaperWaveDynamics documents\biblio\`).
  To change a board, deserialise a **copy**.
- **Never construct `Form_shaper` headlessly** — it pulls in SlimDX/DX11 device creation and a bundled
  `WinSCP.exe`. Scans go through the real GUI.
- **Never commit the licence key.** `.gitignore` blocks `*.reg` and `SWD/backup/`.
- **Never `-AllowUntrustedFiles`.** After any scan session re-approve with `-TrustCurrentLibrary`.
- **Do not accept SWD's advertised 1.1.0.6 upgrade** — it would invalidate the trust manifest and
  possibly the file format.
- The licence cost **EUR 210** and is machine-bound to `HKLM\SOFTWARE\WOW6432Node\swdy\info`.
  Protecting the installation outranks convenience.
