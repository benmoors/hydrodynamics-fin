# 📘 Live-run findings — 2026-08-31

### What the first real driven scan exposed, for the Step 4 SQA pass

Findings from driving `swd_msg.ps1` against SWD for the first time, on
`2003_Taylor_Knox_channel_island` → `..._Copy_1`. **`Set-SwdNumeric`, `Invoke-SwdButton` and the whole
dialog layer had never executed against the real application before this session.**

Severity uses the SQA suite's bars. Every item was **measured**, not reasoned about; where something
is inference it says so.

---

### 🎯 The headline

> **The automation worked and the experiment failed.** The scan ran end to end under tool control —
> 11 angles, 18:16 → 18:28 — but the recovered speed came back **20.0391 m/s on all 53 new operating
> points**, exactly as before. `flow ms = 10` did not reach the solver.
>
> [`WP3-STEP-0-3-verification-scan.md`](../../docs/plans/WP3-STEP-0-3-verification-scan.md) § 7 states the consequence in advance: *"If it still reads ~20,
> the parameter path silently did nothing and Steps 4–7 do not start."* **Step 3 fails its acceptance
> criterion. Step 4 must not start.**

## 📂 0. `[Critical]` The speed parameter path does not work — Step 3 FAILED

| Assertion | Expected | Measured |
|---|---|---|
| Recovered `scan_speed_ms` on the new board | **10.000** | **20.0391 on all 53 rows** |
| Reports parsed | 154 / 154 | ✅ 154 / 154, 0 failures |
| Polar blocks | 1890 / 1890 | ✅ |
| Operating points | grew | ✅ 667 → **720** |
| Boards | 27 → 28 | ✅ |

**What is certain:** the `flow ms` box read `10` when the scan started — logged immediately before the
click — and every resulting operating point recovered ≈20.04 m/s. So **`flow ms` does not drive the
hydroscan.** It belongs to the `Test Position` single-point solver (`Compute` / `Solve Planing`), and
the scan takes its speed from somewhere else.

Supporting oddity: the copy's stored `board_speed_setting_ms` came out **20**, not the `10` the box
showed and not the `10` the original board carried. So `flow ms` is not `_vitesse_flux_relatif_ms`
either.

> ### ⚠️ The copy branch silently reset the board's physics metadata
> This is a second failure, independent of the speed one, and it destroys the other reason this board
> was chosen.
>
> | | Original | `..._Copy_1` |
> |---|---:|---:|
> | `turn_radius_m` | **22.806** | **100000** |
> | `board_speed_setting_ms` | 10 | 20 |
>
> The board was selected precisely because **22.8 m was a turn radius the corpus did not have**. The
> copy SWD made is a straight-line board at 100000 m, a value the corpus is already full of. So the
> run added a hull geometry and **neither** a new speed **nor** a new radius.
>
> Any future "scan a protected board" flow must re-read the board's parameters **after** the copy is
> loaded, never assume they survived, and never describe the copy as equivalent to the original.

### 🔹 Where the speed might actually come from — leads, not conclusions

* **`<no Wave>`.** The window title has read `<no Wave>` throughout, and no wave has ever been loaded
  in any session. If HydroScan derives flow from a wave definition, that would explain a fixed
  default. This is the strongest lead and the cheapest to test.
* **The `Solver option:` group** (`3345034`) was never opened or enumerated.
* A scanner-specific parameter surface may exist that we never reached — the panel we enumerated is
  the `Test Position` tab, which is where the scan button happens to live.

**Do not run another scan to test a guess.** Each costs ~12 minutes and writes into the library.
Identify the control first, by reading it, the way `flow ms` was identified.

---

### 🎯 What the session did establish

Three defects sit between here and an unattended batch, and one of them silently undermines the exact
rule Step 4 was going to rely on for board identity.

---

## 📂 1. `[Critical]` `Process.MainWindowHandle` is unstable, and the whole toolchain keys off it

**Measured, three different values in one session for one unchanged process (pid 44636):**

| When | `Get-SwdProcess.MainWindowHandle` | Real main window |
|---|---|---|
| Enumeration phase | `1245848` (correct) | `1245848` |
| After the copy branch | **`3804628`** | `1245848` |
| After the scan | window titled **`Starting HydroScan`** | `1245848` |

SWD has **30 top-level windows**. .NET picks "the first" it finds and that choice is not stable.

### 🔹 Three consequences, all live-observed

1. **`Get-SwdDialog` leaks the real main window.** It excludes the main window by comparing against
   this unstable handle, so when the value drifts the comparison fails. Observed returning
   `handle=1245848 … title=[FYN Shaper Wave Dynamics <Board: …>]` as a *dialog*.
2. **`Wait-SwdDialog` therefore never waits.** With no `-TitleLike` it matched the leaked main window
   on the first poll and returned **immediately**, before the real modal existed. The scan-start
   attempt then compared main-window text against `-ExpectLike` and refused.
3. **`MainWindowTitle` can return a dialog's title.** After the scan it read `Starting HydroScan`.

> ### ⚠️ Point of note — this breaks Step 4's board-identity check
> [`WP3-STEP-4-batch-driver.md`](../../docs/plans/WP3-STEP-4-batch-driver.md) § 3 requires verifying board selection **"from the window title, not
> from the call returning success"**. That rule is sound, but the *implementation* it would reach for
> reads `MainWindowTitle`, which is demonstrably capable of returning a modal's caption instead of
> the board title. A driver could confirm the wrong board, or fail to confirm the right one, and both
> failures are silent. **Resolve the main window once, by class + title pattern
> (`WindowsForms10.Window.8*`, `Owner = 0`, title `FYN Shaper Wave Dynamics*`), pin it, and never
> re-read `MainWindowHandle` mid-run.**

## 📂 2. `[High]` `Wait-SwdDialog` without `-TitleLike` cannot be trusted

Direct consequence of § 1, listed separately because it is the actionable rule.

    # returns the MAIN WINDOW instantly - measured
    $d = Wait-SwdDialog -TimeoutMs 30000

    # correct: returned $null when no such dialog existed, and the real
    # dialog (handle 3869522) when it did - both measured
    $d = Wait-SwdDialog -TitleLike 'Starting HydroScan*' -TimeoutMs 30000

**Always pass `-TitleLike`.** Treat the unfiltered form as unsafe until § 1 is fixed.

## 📂 3. `[High]` OneDrive locks the board file mid-scan, and SWD raises a blocking modal

At scan end SWD raised `#32770` / `SurfHydrodynamics`:

> `erreur Serializer_surfboard_bin: The process cannot access the file
> '…\biblio\Boards\2003_Taylor_Knox_channel_island_Copy_1.fynbs' because it is being used by another
> process.`

The library sits inside a **OneDrive-synced Documents tree**, and three OneDrive processes were running.
A newly created 2 MB `.fynbs` is exactly what a sync client grabs. The lock was **free** when tested
minutes later, and the file did end up written (mtime 18:28, 2,082,858 B), so it is transient.

**Why it matters for Step 4:** an unattended 13-board batch creates or rewrites a `.fynbs` per board
inside a synced folder. This modal blocks SWD's message pump, so the batch stalls until something
dismisses it. The driver must either expect this dialog by name and dismiss it, or the run must not
target a synced directory. **This is not hypothetical — it happened on the very first driven scan.**

The `.fynrhydro` reports were unaffected: all 11 wrote correctly. Only the board save failed.

## 📂 4. `[Medium]` The speed control is `flow ms` — m/s, not km/h

`BUILD-NOTES.md:86` and the WP3 plan both assert the speed boxes are
`NumericUpDownScanSpeed{1,2,3}kmh` in **km/h**, with a standing warning to convert via `ConvertTo-Kmh`
and *"never type"* the m/s number.

**Measured: there is no km/h control.** The box is an `EDIT` (`856282`) whose parent panel is labelled
**`flow ms`**, inside `Surfing situation:` on the `Test Position` tab, alongside `Slope°` and
`Surfer Kg`.

Verified by an independent cross-check: the `Surfer Kg` box reads **80** and the window title
independently reports `<Surfer: Surfer Pro(80Kg)>`. The labels are literal unit descriptors.

Had the plan been followed, `36` would have gone into an **m/s** box — 36 m/s ≈ 130 km/h, far outside
any surfing envelope. **`ConvertTo-Kmh` must not be used on this control.**

## 📂 5. `[Medium]` There are three scan-flow dialogs, with two different button vocabularies

Full captures in [`SCAN-FLOW.md`](SCAN-FLOW.md). Summary of what the fixtures got wrong:

| # | Title | Buttons | Covered by tests before today? |
|---|---|---|---|
| 1 | `SurfHydrodynamics` | `&Yes` / `&No` | ❌ |
| 2 | `Saving file` | `&Yes` / `&No` | ❌ |
| 3 | `Starting HydroScan` | `OK` / `Cancel` | ✅ (`'*more than 60 mn*'` matches) |
| 4 | `SurfHydrodynamics` (serializer error, § 3) | `OK` | ❌ |

Dialogs 1 and 2 fire only for a **protected** library original. Dialog 2's text embeds the board
filename, so its `-ExpectLike` cannot be a fixed literal across boards.

## 📂 6. `[Medium]` `Test-SwdOwnsForeground` called without its mandatory parameters hangs silently

It takes `-Handle` and `-ProcessId`, both `[Parameter(Mandatory)]`. Called with neither, PowerShell
raises an **interactive prompt** rather than an error. In a background or elevated shell that prompt
is invisible and unanswerable: the process hangs indefinitely and survives `taskkill` from a
Medium-integrity shell.

Reproduced twice, costing two elevated runs. **Caller error, not a defect in the function** — but it
is a live hazard for an unattended driver, where nothing is watching to notice a stall. Consider
whether a driver-facing wrapper should supply the foreground handle itself.

## 📂 7. `[Corrected]` Timing — the earlier "2.7x faster at 10 m/s" claim is WITHDRAWN

An earlier version of this file reported ~61 s per angle "at 10 m/s" against ~163 s "at 20 m/s" and
concluded the solver is 2.7x cheaper at lower speed. **That inference is invalid and is withdrawn.**

The scan it measured **ran at 20.0391 m/s** - section 0 proves it. So both figures are measurements
at ~20 m/s, and the 163 vs 61 s difference cannot be a speed effect. The remaining candidate is board
geometry or mesh size, which was not controlled.

| Run | Board | Actual speed | Per angle |
|---|---|---:|---:|
| 2026-08-28 | `default_shortboard_Copy_1` | ~20 m/s | ~163 s |
| 2026-08-31 | `..._Taylor_Knox..._Copy_1` | **20.0391 m/s** | ~61 s |
| 2026-08-31 (wave loaded) | same board | wave = 6.59 m/s | **>11 min, none completed** |

**The third row is the only genuine low-speed datum, and it points the opposite way.** With a wave
loaded and an average wave speed of 6.59 m/s, not one of 11 angles completed in 11 minutes, while SWD
stayed actively computing. A board of 2.1 kg carrying an 80 kg surfer at 6.59 m/s is at or below
planing threshold, so the solver has to work far harder to find equilibrium.

**Consequence for Step 4: there is no validated cost model for a low-speed batch.** The ~13 h estimate
was built at ~20 m/s. If the speed axis is reached via slow-converging low-speed cases, the batch
could be far more expensive, not less. Do not plan a batch on the withdrawn 2.7x figure.

## 📂 8. `[Info]` There are no drift min/max/step controls

The WP3 plan specified drift `0 / 20 / 10` → three angles. **No such controls exist in the panel** —
only a `Drift Angle` trackbar and a read-only label. The scan ran SWD's default 11-angle set
(`0, 2, 5, 10, 15, 20, 30, 45, 60, 75, 90`) and the angle count is not parameterisable from the UI
the way the plan assumed.

The `Starting HydroScan` dialog states *"Each Scaned angle Is saved when computed / You can Stop the
scan, And restart it later"*, and this held: files appeared one per angle as computed. **Stopping
early is the only way to limit the angle set**, and partial results survive.

## 📂 9. `[Info]` What worked, and should be the Step 4 pattern

Verified end to end:

    Invoke-SwdButton  -Handle <scan> -Post          # Post, never Send - a Send blocks on the modal
    Wait-SwdDialog    -TitleLike 'Starting HydroScan*'
    Invoke-SwdDialogButton -DialogHandle $d.Handle -ExpectLike '*more than 60 mn*' -ButtonLike 'OK'
    Wait-SwdDialogGone -Handle $d.Handle            # observe the dismissal, never infer it

`Set-SwdNumeric` also behaved exactly as documented on its first real execution: `Before=5`,
`After=10`, `Ok=True`, `Reason=ok`, `LastError=0`, with `Slope` and `Surfer Kg` unchanged.

> ### 💬 Aside — the safety gate earned its keep on day one
> When § 1's defect fed main-window text to `Invoke-SwdDialogButton`, it returned
> `Matched=False`, `Attempted=False`, `Reason='dialog text does not match -ExpectLike; REFUSED
> without clicking'`. **Nothing was clicked and no scan started.** A driver that blind-clicked the
> affirmative button would have pressed an unknown control on a licensed install. The refusal looked
> like a failure and was the system working.

## 📂 10. `[Info]` Unfocused message delivery — evidence, not proof

Clicking `Apply situation` with `Test-SwdOwnsForeground` returning **`False` both before and after**
gave `Sent=True`, `Observed=handled`, `LastError=0`.

So an elevated message reached SWD **while it did not hold the foreground**. That is the first
real-application evidence for the headless premise, which had only ever been an inference.

**It is not proof the control acted.** No observable state changed — `flow`, `Slope`, `Surfer Kg`,
the drift label and the title were byte-identical either side. `Apply situation` may simply be a
no-op when values are already current. Microsoft's *"BM_CLICK might fail on an inactive dialog"*
caveat is about transport, and transport is what was demonstrated, but **TODO worklist item 1 should
be closed only by a probe on a control whose caption changes.**

---

## 📂 11. Open

* **A surfer mass of 50 kg was reported on screen** during the run. Every instrument read **80** —
  the `Surfer Kg` box, the window title (`Surfer Pro(80Kg)`), and the configuration panel
  (`Displacement (board+surfer) 80.10 Liters`). No visible control matched `50`. **Unresolved; the
  control has not been located.** Worth settling, because surfer mass enters the planing solution.
* Whether the failed board save (§ 3) left `_vitesse_flux_relatif_ms` stale in the copy's `.fynbs`.
  Metadata only — [`CLAUDE.md`](../../../CLAUDE.md) § 6 already records the stored setting is not the scan speed — but the
  next extraction should be read with this in mind.
