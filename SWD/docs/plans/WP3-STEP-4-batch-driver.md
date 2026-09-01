# WP3 Step 4 — the batch driver `swd_scan.ps1`

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



**Stage plan, written 2026-08-29 for execution Monday 2026-08-31.** Standalone: everything needed is
here.

> ### 🚦 Prerequisite — do not start otherwise
> **`WP3-STEP-0-3-verification-scan.md` Step 3 must have PASSED**, meaning the re-extracted
> `scan_speed_ms` for `2003_Taylor_Knox_channel_island` reads **10.000, not 20.039**. If it still
> reads ~20, the parameter path silently did nothing and there is nothing worth automating yet.
>
> **Deferred to Monday deliberately.** This stage needs a full SQA pass, which does not fit the
> weekly usage limit. Everything else in WP3 is cheap; this is where the budget goes.

**Unlocks:** `WP3-STEP-5-7-batch-run.md`.

> ### ❌ PREMISE REFUTED 2026-08-31 — read before acting on anything below
>
> This stage exists to obtain a **second physical scan speed**. That is not achievable.
>
> A verification scan was driven end to end with the speed input set and readback-asserted at 10.
> All **53** resulting operating points recovered **20.0391 m/s**, unchanged. The `flow ms` box drives
> the single-point solver only (proved independently: `Solve Planing`'s caption reads back
> `Relative speed:10 m/s`), and an exhaustive control enumeration found **no scan-speed control
> anywhere** — `Solver option:` holds three buttons and no numerics. Evidence:
> `SWD/tools/phase2/LIVE-RUN-FINDINGS.md` § 0, `SWD/docs/what-swd-can-yield.md` § 3.
>
> **Do not run this batch for speed.** It would return 26 boards at the same ~20 m/s the corpus
> already has, at 5–13 hours of machine time.
>
> **The machinery is sound and reusable.** Board switching, the dialog layer and the scan driver are
> still what a batch needs — they just need pointing at a different axis. Candidates, by
> evidence-per-minute:
>
> | Axis | Cost | State |
> |---|---|---|
> | **Surfer mass** — 11 `.fynsurfr` profiles incl. explicit 65 kg / 95 kg; `m` is a paper symbol | ~24 min to settle | **untested, highest value** |
> | **Geometry** — 13 unscanned boards, or parametric sweeps via `Apply Length/Width/Volume` | ~12 min per board | available |
> | **Fin configuration** — 7 static + 2 dynamic fins, toe/cant angles editable | unmeasured | available |
>
> None is a commitment. See `SWD/docs/project-io-spec.md` § 8.


---

## 1. Why this exists

`SWD/data/operating_points.csv` has 667 rows and every channel the surrogate needs, but
`scan_speed_ms` holds **one physical value** (20.000 / 20.039 m/s, the second being float noise). All
143 existing reports ran at that single condition, so nothing trained on the corpus can speak to
speed dependence. Speed is a top-level input in `surfing-performance-io.md` § 4.1, and the heaviest
rubric item (**25 %**) is *Validation and engineering credibility*. `turn_radius_m` is settled as
per-board metadata (constant within 13 of 13 scanned boards), so speed is the one axis still
recoverable by scanning.

**The scope decided 2026-08-29:** all **26 distinct boards** at **10 m/s (36 km/h)** across the
**11 default drift angles** `0, 2, 5, 10, 15, 20, 30, 45, 60, 75, 90`.

- **13 already-scanned boards.** This is the half that matters — the same hull at two speeds is the
  only thing that breaks the speed/board confound. Scanning only new boards would leave every 10 m/s
  row on a board with no 20 m/s row, and the surrogate still could not separate the two.
- **13 unscanned boards**, for geometry variety. `default_shortboard_Copy_2` is skipped: it matches
  `Copy_3` to full float precision on mass, volume and foam mass, so it would add pseudo-replication,
  not information.

**≈13 hours**, two nights. Re-base that from the per-angle time Step 3 measured at 10 m/s — the
~163 s figure came from a 20 m/s run and the solver may not cost the same.

---

## 2. The one missing capability: board switching

Searched 2026-08-29 for `Select-SwdBoard`, `Open-SwdBoard`, `TVM_*`, `SelectionItem`, `TreeView` and
`swd_scan.ps1` across the repository, the scratchpad and every QA backup. **Nothing exists.** It was
never needed while the target was a single board a human had already loaded.

The board library is a `SysTreeView32` — handle `133600` in the 2026-08-29 session, child of `133598`
inside the `Project` tab. **Handles do not survive a process restart; take a fresh one.**

### Route: UI Automation, not Win32, not `swd_ui.ps1`

| Route | Verdict |
|---|---|
| Cross-process `TVM_GETITEM` | **No.** `TVITEM` carries a pointer to a text buffer in the *target's* address space, so this needs `VirtualAllocEx` + `WriteProcessMemory` + `ReadProcessMemory` inside a licensed application. A large blast radius for a cosmetic gain |
| `swd_ui.ps1` (`SendInput` + `SetForegroundWindow`) | **No.** It moves the real cursor and steals the foreground — and **`SendInput` fails against a locked workstation**, because the secure desktop takes over. Disqualifying for a 13 h unattended run |
| **UIA `SelectionItemPattern.Select()`** | **Yes.** No cross-process memory, no cursor, no foreground theft, and it survives a locked session |

Supporting measurement: UIA from a Medium-integrity shell returns 98 bare `Pane`s; **elevated it
returns 131 named elements.** So the driver must run elevated regardless — which it already must, for
UIPI.

Corroborating design signal: `Test-SwdOwnsForeground` (`swd_msg.ps1:761`) already returns `$null`
rather than `$false` when `GetForegroundWindow` returns 0 — *"the workstation is locked, the secure
desktop (UAC) is up, or focus is between windows"*. The codebase already anticipates running while
locked; do not regress that by reaching for `SendInput`.

**Environment fact:** section D of the diagnostic loads `UIAutomationClient`, a .NET **Framework**
assembly, so the driver runs under **Windows PowerShell 5.1**, not `pwsh` 7. All files must still
*parse* under 7.

---

## 3. Driver shape

Per board, in order:

1. **Back up** that board's `rapports_hydro/<board>/` before touching it — see § 4
2. **Select** the board in the tree (UIA), then **verify** the selection from the window title, not
   from the call returning success
3. **Set** speed and the three drift parameters with `Set-SwdNumeric`, which reads back and asserts
4. **Start**, then handle the confirmation with `Invoke-SwdDialogButton -ExpectLike '<real caption>'`
5. **Wait**, then **confirm the report files exist on disk** — the only honest completion signal
6. **Next**

### Non-negotiables

- **Detached**, logging to a file. A 13-hour run cannot be held open in a conversation, and
  babysitting it is the one thing that would make this expensive in tokens.
- **Resumable from a state file.** Thirteen hours *will* be interrupted. The state file records which
  boards are done, so a restart does not re-scan and does not skip.
- **A "save changes?" modal on board switch is likely** — SWD rewrote `default_shortboard_Copy_1.fynbs`
  at 05:41:28 after its last report. `Invoke-SwdDialogButton`'s `-ExpectLike` gate covers it, but the
  caption must be **read before it is trusted**, exactly like the scan confirmation.
- **Never blind-click OK.** The safety property of the dialog layer is that it refuses to click unless
  the dialog's own text matches a pattern the caller stated in advance. A driver that accepts whatever
  dialog is up will eventually accept *"Delete this hydroscan?"* — on a licensed install holding 143
  reports, that is not recoverable. Mutation-checked: neutering the gate (`$matched = $true`) is
  killed by 2 tests.
- **Never trust `Sent`.** `lastError=1460` is ambiguous — SQA measured two sends to a blocked UI
  thread both returning 1460 with the target's click counter at **0**. Confirm outcomes by observing
  state: `Get-SwdTransportOutcome`, `Wait-SwdDialogGone`, then files on disk.

---

## 4. The overwrite hazard — the reason step 1 above is not optional

Reports are stored as:

```
rapports_hydro/<board>/drift_<angle>.fynrhydro
```

**The speed is not in the filename.** A 10 m/s scan of an already-scanned board writes
`drift_0.fynrhydro` straight over its 20 m/s predecessor. Same angles, same names, silent
replacement — and that is the entire existing corpus.

| | |
|---|---|
| `rapports_hydro/` total | **590 MB** (13 boards × 11 files × ~4 MB) |
| Free space on C: | 546 GB |
| Backup destination | `%USERPROFILE%\SWD-backup\<date>\` — **outside the repo**, per `CLAUDE.md` § 4 |

Back up **before** each board is scanned, not once at the start, so an interrupted run never leaves a
board half-overwritten with no copy. `WP3-STEP-5-7-batch-run.md` § Step 6 is what turns those backups
back into a two-speed dataset.

---

## 5. The SQA gate — mandatory

`CLAUDE.md` § 4: *"Run an SQA pass over any new `.ps1` that touches SWD before running it against the
real installation."* Same gate `swd_msg.ps1` went through.

| Setting | Value |
|---|---|
| Goal class | `functionality` |
| Specialists | **`sqa-functional` only** — the standing preference for this project |
| Fixer | **one `code-reviewer` per round**, continued across rounds via `SendMessage` |
| Verifier | always a **fresh** `sqa-lead` — an agent must never certify its own fixes |
| Cap | ~3 rounds, then stop and report what is outstanding |
| Gate | the `VERDICT:` line — loop while `Critical`/`Warning` > 0, stop on `(CLEAN)` |

Snapshot before starting: `~/.claude` is a git repo, so commit on a working branch, and keep the
file-copy staging pattern (`.pre-reviewer`, `.pre-roundN`, `.post-roundN`) that makes reverting a
single round possible.

**Anti-gaming, from the QA loop protocol:** the fixer gets **no write access** to the guard, the
tests, or `qa-history/`. A fixer that can edit its own scorecard is the same defect as one that can
edit its own tests.

> ### ⚠️ The guard is known-weak — do not quote its number without re-running it
> The Pester suite is **not reproducible**: 257/1, then 254/4 with *different* tests failing, then
> 236/1; the diagnose suite alone swings between 10 and 21 passes. All failures are timing-dependent
> assertions, none is a safety gate — but *a guard that varies cannot gate anything*. This is open
> suspect **19** in `~/.claude/qa-history/swd-phase2.md`, and **fixing it belongs in this stage**,
> because Step 4 is the first time the suite is asked to gate a real change.
>
> The 54 safety-gate tests are stable (**54/0 twice**) and are the trustworthy subset.

---

## 6. Verification

| Check | Passes when |
|---|---|
| SQA | a fresh `sqa-lead` returns `Critical=0 \| Warning=0`, or the cap is reached and the outstanding items are reported |
| Board switching | demonstrated on **≥2 boards**, each confirmed from the window title |
| Idempotence | re-running with a populated state file scans nothing and skips nothing |
| Dry run | a full single-board cycle completes without a human present |
| Locked session | one board scanned with the workstation locked — this is the claim the whole route rests on |

---

## 7. Standing constraints — `CLAUDE.md` § 4, quoted not referenced

- **Never write inside `C:\Program Files\ShaperWaveDynamics\`.**
- **Never modify a file in `biblio\` in place** — deserialise a **copy**. Documents is redirected to
  `%OneDrive%\Documents\`.
- **Never construct `Form_shaper` headlessly.**
- **Never `-AllowUntrustedFiles`**; re-approve with `-TrustCurrentLibrary` after each scan session.
- **`BinaryFormatter` needs Windows PowerShell 5.1.**
- **Do not accept SWD's advertised 1.1.0.6 upgrade.**
- **Never commit the licence key.**
