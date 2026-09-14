# Phase 2 — generating more hydroscans

**Status: unblocked as of 2026-08-27.** The blocker was UIPI, and the fix is to run the automation
elevated. This document was substantially wrong between 26 and 27 August; § 5 records what it got
wrong and how, because the mistake is more instructive than the fix.

Working record, kept in the same register as [`SWD/TODO.md`](../TODO.md).

---

## 1. Why Phase 2 exists

All **143** hydroscans ran at **one speed (~20 m/s)** across **nine turn radii**, on 13 of the 27
boards in the library. The dataset therefore supports no statement about speed dependence at all.
The only way to change that is to run SWD's own HydroScan at other conditions.

*(The 2026-08-28 scan added 11 reports and a 13th board, but ran at the loaded settings — ~20 m/s —
so it did not touch the speed axis. Also settled that day: **turn radius is per-board, not
per-operating-point**, constant within 13 of 13 scanned boards. See `data/coverage.md`.)*

Three sources of new data, cheapest first:

| # | Action | Yield |
|---|---|---|
| 1 | Scan the 13 genuinely distinct unscanned boards at their existing settings | ~660 operating points (143 reports), plus the only three **negative** radii in the library. **~6 h at the measured rate.** Skip `default_shortboard_Copy_2` — a geometric duplicate of the already-scanned Copy_3 |
| 2 | Re-scan at other speeds via `scanSpeed1/2/3_kmh` | the missing speed axis |
| 3 | Edit `rayon_planning_m` on board copies and re-scan | a denser radius axis |

Step 1 needs no parameter editing at all and is the obvious first move — **after** a single
verification scan has proved the mechanism end to end.

---

## 2. What is already proven

**The round-trip gate passes.** A `.fynbs` copy was deserialised, re-serialised unchanged, and
compared field by field: **59 of 59 serialised scalars identical, 0 differences**, including the two
Phase 2 needs to edit (`_vitesse_flux_relatif_ms`, `rayon_planning_m`). The 26-byte size difference
is `BinaryFormatter`'s own encoding, not data loss. Writing modified board copies is safe.

Serialisation is plain and field-based — no `ISerializable`, no `[OnDeserialized]` callbacks anywhere
in the assembly — and 151 of `Class_surfboard`'s 231 fields are `[NonSerialized]`, so SWD rebuilds
all derived geometry on load. Only the two numbers need changing.

**The extractor needs no changes.** New `.fynrhydro` files are picked up automatically. They will,
however, be refused by the provenance gate until approved — see § 6.

---

## 3. What SWD's UI actually looks like

Measured 2026-08-27 from an **elevated** shell. Everything in this section was different, and largely
useless, when measured unelevated — see § 5.

- The entry point is a **"Hydrodynamics Scanner"** button in the lower-left panel, not a menu item.
  Its window handle in the 12:13 session was `19726830`, class
  `WindowsForms10.BUTTON.app.0.141b42a_r7_ad1`, enabled.
- With no scan present the project tree shows a greyed **"No HydroScan"** node and the message:
  *"No HydroScan for this board. Scaned drifts angles list is empty. Use the Scaner tool to add and
  save new drift angles to the hydroScan of the board"*.
- Top-level tabs are **Shape Room** and **Wave Room**. The title bar reported `<no Wave>` throughout,
  so a wave may be a precondition for scanning — **still unconfirmed**.
- In-app warning: *"HydroScan can takes more than 60 mn"* per board. File timestamps on the existing
  scans suggested 12–21 minutes, ~95 s per drift angle. **That estimate was optimistic.** A scan
  driven and timed end to end on 2026-08-28 took **~30 minutes for 11 drift angles, ≈163 s each**
  (05:11:22 → 05:41:04). **Use 163 s.** Still about half the app's own warning, but not the 4×
  saving the earlier figure implied — every batch estimate built on 95 s is ~1.7× too cheap.
- A newer SWD version (1.1.0.6) is advertised in the title bar. Installed is 1.0.8.1. Upgrading
  mid-project would invalidate the trust manifest and possibly the file format — **do not upgrade
  without re-running the full verification.**

### The controls are real Win32 child windows — 181 of them

`EnumChildWindows` over the main HWND returns **181** descendants (the count depends on what is open;
an earlier session recorded 165):

| Class | Count |
|---|---:|
| `WindowsForms10.Window.8.app…` | 89 |
| `WindowsForms10.BUTTON.app…` | 27 |
| `WindowsForms10.EDIT.app…` | 22 |
| `WindowsForms10.STATIC.app…` | 12 |
| `WindowsForms10.msctls_trackbar32.app…` | 11 |
| `WindowsForms10.SysTabControl32.app…` | 7 |
| `WindowsForms10.COMBOBOX.app…` | 4 |
| `Edit` | 4 |
| `WindowsForms10.SysTreeView32.app…` | 2 |
| `SCROLLBAR`, `msctls_updown32`, `LISTBOX` | 1 each |

So the app can be driven by `BM_CLICK` and `WM_SETTEXT` straight to handles — no cursor, no
coordinates, no focus. That is what makes an unattended scan possible without taking over the
machine.

> ### ⚠️ The scan parameter controls do not exist until the scanner is opened
> There is exactly **one** `msctls_updown32` in the whole application and **nothing** whose text
> mentions drift or speed. `NumericUpDown_scan_drift_{mini,maxi}`, `NumericUpDown_scan_step` and
> `NumericUpDownScanSpeed{1,2,3}kmh` are named in the assembly but are not instantiated on startup —
> the panel is built on demand, which is exactly what the app's own "use the Scaner tool" message
> says. **The control map is therefore two-stage**, and a scan driver cannot be written against a map
> taken before the scanner is open.

---

## 4. Two coordinate bugs — fixed, and now irrelevant

These wasted real time and would waste it again, but they only apply to the **fallback** cursor route
in `tools/phase2/swd_ui.ps1`. The message route in `tools/phase2/swd_msg.ps1` never computes a screen
coordinate, so neither can affect it.

**DPI.** The display runs at ~173 % scaling. UI Automation reports **physical** pixels (primary
monitor 3200×2000) while a DPI-unaware process sees 1845×1111. Call `SetProcessDPIAware()` first and
both coordinate spaces agree.

**Multi-monitor.** The desktop spans two screens — virtual origin **(−3360, 0)**, size **6560×2112**,
secondary to the *left* of the primary. `SendInput` with `MOUSEEVENTF_ABSOLUTE` normalises against
the **primary monitor only** unless `MOUSEEVENTF_VIRTUALDESK` is also set. Without it, targeting
(48, 68) put the cursor at (−1227, 1235) — on the other monitor.

```
nx = (x - SM_XVIRTUALSCREEN) * 65535 / (SM_CXVIRTUALSCREEN - 1)
ny = (y - SM_YVIRTUALSCREEN) * 65535 / (SM_CYVIRTUALSCREEN - 1)
flags |= MOUSEEVENTF_VIRTUALDESK
```

---

## 5. The blocker was UIPI — and this section used to say otherwise

**The fix: run the automation process elevated.** Everything else was a red herring.

### The measurement

One variable changed between two runs, twenty seconds apart, against the same SWD process (pid 42488):

| | Non-elevated shell | Elevated shell |
|---|---|---|
| This shell | Medium `S-1-16-8192` | High `S-1-16-12288` |
| SWD | **token unreadable** | High `S-1-16-12288` |
| UIA descendant elements | **98, every one a bare `Pane`** | **131, named** — 15 Button, 8 MenuItem, 16 Text, 6 Group, 2 ComboBox, 3 Separator, ToolBar, StatusBar, MenuBar, Thumb, 77 Pane |
| `SetCursorPos` + cursor lands | True / True | True / True |
| `BlockInput(false)` | `False`, lastError **5** | `False`, lastError **0** |

SWD's manifest requests `highestAvailable`, and `moors` is a member of `BUILTIN\Administrators`
(currently *"used for deny only"* — a UAC split token), so SWD runs elevated. Microsoft's own
description of the mechanism: *"UIPI implements restrictions… that prevent lower-privilege
applications from sending messages or installing hooks in higher-privilege processes."* The
documented bypass, `uiAccess`, requires a digitally signed binary in a protected folder, so it is not
available to us — and is unnecessary once both processes sit at the same level.

### What this section previously claimed, and why it was wrong

Two claims were load-bearing and both are false:

**"Same integrity level as SWD, so UIPI is not the cause."** They were not the same level. Nothing in
the earlier work appears to have compared the tokens directly; the claim looks like an assumption
that was written down as an observation. It is the single most expensive sentence in this repository.

**`BlockInput(false)` returning `ERROR_ACCESS_DENIED` "means another process holds an input block."**
It does not. The elevated run returns `False` with **lastError 0**, and in *both* runs `SetCursorPos`
succeeds and the cursor actually lands — so there is no block in either. Error 5 there is simply what
a non-elevated caller gets. An inference was drawn from a single API return code without a control.

> ### 💬 Aside
> The distinguishing test named in the earlier version of this document was right and is worth
> keeping: `SetCursorPos` followed by `GetCursorPos`. If the cursor does not move, the problem is not
> your coordinates. The error was not the test, it was reading a *second* signal — `BlockInput`'s
> return — as corroboration when it carries no such information.

### Still genuinely unexplained

`SetCursorPos` returning **`False`** on 26 August is real and is not explained by UIPI. It does not
reproduce now. Something was interfering that day; what it was is unknown, and the honest position is
that one of the two pieces of evidence for it was worthless while the other still stands unexplained.

### An unexpected result worth keeping

**Reads cross the integrity boundary.** `EnumChildWindows` and `WM_GETTEXT` returned real text for
all 181 controls from a *Medium* shell — the enumeration in § 3 does not require elevation at all.
UIPI filters state-changing messages, so the sharp prediction is that `BM_CLICK` and `WM_SETTEXT`
fail unelevated and succeed elevated. Running the click probe from both shells settles it in one pair
of measurements, and turns "the headless route works" from an inference into a demonstration.

### Affirmatively ruled out — do not re-investigate

SWD has **no** DirectInput, **no** Raw Input, **no** `SetWindowsHookEx`, **no**
`ClipCursor`/`SetCapture`/`BlockInput`, **no** `WndProc`/`ProcessCmdKey` override, **no**
`IMessageFilter`, **no** custom controls, and **no** full-screen exclusive DirectX (the swap chain is
windowed into a child HWND). The cursor clip observed on 26 August was not SWD's doing.

---

## 6. Resuming

The tooling lives in `tools/phase2/`: `swd_msg.ps1` (message primitives), `swd_diagnose.ps1`
(read-only diagnostic), `swd_ui.ps1` (cursor fallback), and [`BUILD-NOTES.md`](../tools/phase2/BUILD-NOTES.md) (the production record,
including an explicit list of what has *not* been verified).

1. **Launch SWD by hand**, then run the automation from an **elevated** shell:
   ```powershell
   # RunAs starts in a different working directory, so -File must be absolute.
   $diag = Join-Path $PWD 'SWD\tools\phase2\swd_diagnose.ps1'
   Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass',
     '-File',$diag
   ```
2. **Open the scanner panel and re-take the control map** — the parameter controls do not exist
   before that (§ 3).
3. **Drive one scan end to end and verify the resulting `.fynrhydro`** before batching anything. Make
   it a cheap one: 3 drift angles instead of 11, at a speed other than 20 m/s, on one of the 15
   boards that have no hydroscan so nothing can be overwritten. **The speed boxes are km/h** — 10 m/s
   is 36 km/h, and typing `10` asks for 2.78 m/s and yields a plausible wrong scan.
4. **Verify by re-extraction, never by the GUI reporting success.** The extractor recovers speed
   independently from the planing mass balance `ṁ = ρAV`; if 10 m/s was set, `ṁ/A` must imply 10.000,
   not 20.000.
5. **Re-approve the library after each scan session** — new files are refused until then, and
   `-AllowUntrustedFiles` must never be used to dodge it:
   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "SWD\tools\swd_extract.ps1" -TrustCurrentLibrary
   ```
6. **Re-extract and regenerate `data/coverage.md`.**

**The open question to settle on the first run:** whether turn radius is persisted numerically per
operating point. `global_scan` hands radius back as an `Image`, while `Create_Chart_scan_radius`
takes a `Single[]`. Whether that array reaches disk decides whether radius is a per-point value or
stays one value per board. One scan and a re-extraction answers it; no amount of further reading will.

### If automation stays blocked

The fallback is running the scans by hand. Nothing else changes: the extractor picks up whatever
appears in `rapports_hydro\<Board>\`, and the trust manifest step is the same. The cost is the same
~30 minutes per board either way — **automation buys back attention, not time.**
