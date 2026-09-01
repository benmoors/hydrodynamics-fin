# 📘 The SWD scan flow, as measured

### What `swd_scan.ps1` must handle — captured live, not inferred

Every dialog and transition below was observed on **2026-08-31** while driving
`2003_Taylor_Knox_channel_island` by hand with Claude enumerating read-only between clicks. Nothing
here is copied from an earlier document; where a prior claim was refuted, this file says so.

**Handles are session-scoped.** Every number in this file belonged to SWD **pid 44636**. They do not
survive a restart. Take fresh ones from `control-map.csv`. The *structure* is what transfers.

---

### 🎯 Why this file exists

> * The driver's dialog handling was written against **one** dialog. There are at least **three**.
> * All three use **`&Yes` / `&No`**. The test suite assumes `OK`. A driver looking for an OK button
>   finds nothing on any of them.
> * The scanner panel does not exist until the scan button is clicked, and a protected board diverts
>   through a copy-creation branch before the panel ever appears.

---

## 📂 1. The dialog sequence

All are class **`#32770`**, owned by the main window. This settles ledger **suspect 20** — the
`#32770` claim withdrawn at `swd_msg.ps1:1564-1570` was **correct**, at least for these three.

### 🔹 Dialog 1 — protected-board gate

Raised by clicking `Hydrodynamics Scanner`. **Only for a protected library original.**

| | |
|---|---|
| Title | `SurfHydrodynamics` |
| Text | `this Board model is protected and must be saved as copy before scan, save board?` |
| Buttons | `&Yes` · `&No` |

### 🔹 Dialog 2 — load-the-copy confirmation

Follows `&Yes` on dialog 1.

| | |
|---|---|
| Title | `Saving file` |
| Text | `2003_Taylor_Knox_channel_island.fynbs`<br>`Is an exemple board protected`<br>`Do you want to load a copy` |
| Buttons | `&Yes` · `&No` |

The text embeds **the board's filename**, so an `-ExpectLike` pattern for this one must be built per
board or must match loosely on the fixed tail (`*Is an exemple board protected*`).

### 🔹 Dialog 3 — duration confirmation

**Not yet captured.** Recorded on 2026-08-28 against an already-unprotected board as reading
*roughly* `HydroScan can take more than 60 mn - do you want to proceed`. That wording is a
**self-flagged paraphrase** and has never been read from the live control.

> ### ⚠️ Point of note — the string in the test suite is not evidence
> `'*more than 60 mn*'`, used throughout `tests/swd_msg.Tests.ps1`, traces to a 2026-08-27 in-app
> warning that was reused as a synthetic WinForms label in a throwaway harness. It has **never** been
> matched against a real SWD dialog. Treat it as a placeholder until dialog 3 is captured the way 1
> and 2 were.

---

## 📂 2. What the driver must do differently

1. **Match `&Yes` / `&No`, not `OK`.** The ampersand is in the window text.
2. **Branch on board protection.** A protected original diverts through dialogs 1 and 2 and ends up
   on a *different board* than the one selected. An unprotected copy goes straight to the scan path.
3. **Re-read the loaded board after any copy branch** — see § 4. The board that gets scanned is not
   the board that was selected.
4. **Keep `-ExpectLike` per-dialog.** One pattern cannot cover all three, and the safety property is
   that a non-match **refuses** rather than clicking. That is the correct failure and it is why an
   automated run today would have stalled here instead of accepting an unknown dialog.

> ### 💬 Aside — the refusal is the feature
> Had the driver run unattended tonight it would have hit dialog 1, failed to match
> `'*more than 60 mn*'`, and stopped. That looks like a bug and is in fact the gate doing its job.
> The alternative design, blind-clicking the affirmative button, would have answered *"save a copy?"*
> and *"load a copy?"* correctly by luck, and will one day answer *"Delete this hydroscan?"* the same
> way, on an install holding 143 irreplaceable reports.

---

## 📂 3. Panel construction — measured child counts

The scanner panel is built on demand inside the **main window**, not as a separate top-level window.
This confirms outcome (b) in `docs/plans/WP3-STEP-0-3-verification-scan.md` § 4.

| State | Main-window children | `msctls_updown32` |
|---|---:|---:|
| Board loaded, scanner closed | **166** | 1 |
| Mid-transition, dialog 1 up | **131** | 1 |
| Fins tab open, scanner closed | **238** | 1 |

The 166 → 131 drop reproduces the 165 → 130 transition in
`logs/20260828-050934-diagnose.log`: many existing controls flip `Visible` to `False` while panel
controls appear, so **the count falls rather than rises**. A driver that waits for the child count to
*grow* will wait forever.

Three visible `EDIT` controls appeared in a row during the transition, evenly spaced on one line:

| Handle | Rect |
|---|---|
| `856282` | `1529,714,1572,734` |
| `593918` | `1589,713,1632,733` |
| `1248972` | `1647,713,1690,733` |

A triplet of that shape is either drift min/max/step or the three
`NumericUpDownScanSpeed{1,2,3}kmh` boxes. **Not yet identified** — the panel tore down before it
could be read with the pump free. Identify by reading values, never by position alone.

> ### ⚠️ `BUILD-NOTES.md:86` is still unsupported
> It asserts *"A WinForms `NumericUpDown` is an `EDIT` plus an `msctls_updown32` buddy."* The count
> stayed at **exactly 1** across all three states above, and that one's parent is a
> `SysTabControl32` — a tab spinner. So either no `NumericUpDown` was instantiated in any state
> observed, or the assertion is wrong. **Nothing downstream depends on it**: `Set-SwdNumeric` targets
> the `EDIT` and readback-asserts either way.

---

## 📂 4. The copy branch changes which board gets scanned

Answering `&Yes` twice produced a new board and **loaded it in place of the selection**:

| | |
|---|---|
| Created | `biblio/Boards/2003_Taylor_Knox_channel_island_Copy_1.fynbs`, **2,082,947 B** |
| Original | `biblio/Boards/ShortBoards/2003_Taylor_Knox_channel_island.fynbs`, **2,112,831 B**, mtime still **2021-04-27** — untouched |
| Also written | `biblio/temp/image_dessous.png`, `logswd.txt` |

Two things a driver must not miss:

- **The copy lands in `biblio/Boards/`, not in the original's `ShortBoards/` subfolder.** Any code
  that derives a board name from a fixed parent hop will get this wrong. `swd_extract.ps1` already
  takes the first segment under `rapports_hydro` (round-1 finding W3), so extraction is unaffected —
  but a driver walking `Boards/` must not assume the tree shape is preserved.
- **The copy is 29,884 bytes smaller** than the original. SWD re-serialised rather than byte-copied.
  Cause unknown, recorded rather than explained. Do not describe the copy as identical to the original.

### 🔹 The window title is the board-identity oracle

    FYN Shaper Wave Dynamics   <Board: 2003_Taylor_Knox_channel_island_Copy_1(2133.6mm)> <no Wave> <Surfer: Surfer Pro(80Kg)>

It carries the loaded board name, its length, wave state and surfer mass, and it updates on load. The
Step 4 plan already requires verifying board selection "from the window title, not from the call
returning success" — this is that oracle, and the copy branch is exactly why the rule exists. A driver
that selected a protected board and trusted its own `Select()` return would scan
`..._Copy_1` while reporting the original.

`<no Wave>` is still present, so the long-standing question of whether a wave is a precondition for
scanning remains open.

---

## 📂 5. New entities this session created

Both need handling before the next extraction, and neither existed when the current data was built:

1. **A 27th → 28th board.** `2003_Taylor_Knox_channel_island_Copy_1` will appear in `boards.csv`.
2. **A trust-manifest gap.** The manifest holds **383** entries and does not know the new `.fynbs`.
   `swd_extract.ps1` will refuse it by name until `-TrustCurrentLibrary` is re-run. That refusal is
   the provenance gate working; **never** reach for `-AllowUntrustedFiles` to get past it.

---

## 📂 6. What is still unmeasured

Listed so nothing here reads as more settled than it is.

* **Dialog 3's real text**, and whether accepting it starts the scan immediately or merely opens the
  configured panel.
* **Whether declining dialog 3 leaves the panel open.** The whole parameter-setting approach depends
  on this, and it is the next thing to find out.
* **Which triplet the three `EDIT`s at y≈713 are**, and where the other triplet lives.
* **Whether a `NumericUpDown` ever emits an `msctls_updown32` here** (§ 3).
* **Whether an unfocused `BM_CLICK` lands** — the headless premise, still an inference.
