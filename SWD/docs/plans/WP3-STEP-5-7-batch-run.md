---
type: plan
status: todo
worklist: SWD/docs/worklist/04-wp3-steps-5-7-batch-run.md
---

# WP3 Steps 5–7 — the batch, dual-speed extraction, and correcting the record

> ### ⚠️ Correction, 2026-09-01 — `20.0391 m/s` is not a speed
> Decompiling `Form_shaper.actualiser_fluide()` showed SWD picks water density from a
> **4-entry lookup table** (salt `1028/1027/1025/1023` by temperature ∈ {0,10,20,30} °C),
> never a formula. `mass_flux/frontal_section` is exactly `ρ·V` and takes exactly two
> corpus-wide values, **20460.0** and **20500.0** = `1023×20.000` and `1025×20.000`.
> So the corpus is **one flow speed (20.000 m/s) at two water temperatures**, and the
> phantom second speed was `20500/1023 = 20.0391` — the 1025-density scans divided by an
> assumed 1023. Wherever this file treats 20.039 as a speed or as float noise, read it as
> a ρ = 1025 scan instead. **The conclusion that `flow ms` does nothing is unaffected and
> in fact strengthened**: the flow speed was 20.000 throughout. See [`CLAUDE.md`](../../../CLAUDE.md) § 5.



**Stage plan, written 2026-08-29.** Standalone: everything needed is here.

> ### 🚦 Prerequisite
> **[`WP3-STEP-4-batch-driver.md`](WP3-STEP-4-batch-driver.md) complete** — `swd_scan.ps1` written, SQA-cleared, board switching
> demonstrated on ≥2 boards, and one board scanned with the workstation locked.

**This stage is the goal.** Steps 0–4 exist to make it safe.

> ### ❌ PREMISE REFUTED 2026-08-31 — read before acting on anything below
>
> This stage exists to obtain a **second physical scan speed**. That is not achievable.
>
> A verification scan was driven end to end with the speed input set and readback-asserted at 10.
> All **53** resulting operating points recovered **20.0391 m/s**, unchanged. The `flow ms` box drives
> the single-point solver only (proved independently: `Solve Planing`'s caption reads back
> `Relative speed:10 m/s`), and an exhaustive control enumeration found **no scan-speed control
> anywhere** — `Solver option:` holds three buttons and no numerics. Evidence:
> [`SWD/tools/phase2/LIVE-RUN-FINDINGS.md`](../../tools/phase2/LIVE-RUN-FINDINGS.md) § 0, [`SWD/docs/what-swd-can-yield.md`](../what-swd-can-yield.md) § 3.
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
> None is a commitment. See [`SWD/docs/project-io-spec.md`](../project-io-spec.md) § 8.


---

## 1. Why this exists

`SWD/data/operating_points.csv` has 667 rows and every channel the surrogate needs, but
`scan_speed_ms` holds **one physical value** — 20.000 / 20.039 m/s, the second being float noise
around the first. All 143 existing reports ran at that single condition, so nothing trained on the
corpus can speak to speed dependence. Speed is a top-level input in [`surfing-performance-io.md`](../../../surfing-performance-io.md)
§ 4.1, and the heaviest rubric item (**25 %**) is *Validation and engineering credibility*.
`turn_radius_m` is settled as per-board metadata, so speed is the one axis still recoverable.

**Success condition for the whole of WP3: the merged table shows ≥2 distinct physical speeds on the
same board.** Not "two speeds in the dataset" — two speeds on the *same hull*, which is what breaks
the speed/board confound.

---

## 2. Scope

All **26 distinct boards** at **10 m/s (36 km/h)**, **11 default drift angles**
`0, 2, 5, 10, 15, 20, 30, 45, 60, 75, 90`.

| Half | Count | What it buys |
|---|---:|---|
| Already-scanned boards | 13 | **The speed contrast.** The same hull at 20 and 10 m/s — the only thing that separates speed from board identity |
| Unscanned boards | 13 | New geometry. `default_shortboard_Copy_2` skipped: identical to `Copy_3` to full float precision, so it is pseudo-replication |

**≈13 hours, two nights** at the measured ~163 s per drift angle — but that figure came from a 20 m/s
run. **Use the per-angle time Step 3 measured at 10 m/s instead**; the solver need not cost the same
at a different speed.

> **`ConvertTo-Kmh 10` → 36.** The boxes are km/h; typing `10` asks for 2.78 m/s and produces a
> plausible, wrong scan.

---

## 3. Step 5 — run the batch

Two sessions of roughly 6.5 hours. The driver runs **detached**, writing a log and a state file.

**Token cost is near zero, and that is by design.** The log is read afterwards, not during.
Babysitting a running scan is the single thing that would make this stage expensive — Step 4's whole
purpose was to build a driver that does not need it.

`autoContinueAtUsageLimit` is already enabled (`~/.claude/settings.json:86`), so a session that hits
the 5-hour limit waits and resumes itself. After **two consecutive** limit hits Claude Code stops with
`Automatic continue stopped after repeated usage-limit hits`; recovery is `/rate-limit-options` → the
row beginning **Wait here, then continue automatically**, which re-arms with no cap.

**Between the two nights, check:** the state file lists exactly the boards whose report files are on
disk, and no board is half-written.

---

## 4. Step 6 — extract both speeds without losing either

> ### ⚠️ This is the step where the existing corpus can be destroyed
> Reports are `rapports_hydro/<board>/drift_<angle>.fynrhydro`. **The speed is not in the filename.**
> After the batch, each re-scanned board's folder holds only the **10 m/s** reports — the 20 m/s ones
> were overwritten in place. They exist *only* in the backup Step 4 § 4 took.

Sequence, for the **13 re-scanned boards only**:

1. **Extract now** — captures the 10 m/s reports.
   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "SWD\tools\swd_extract.ps1" -TrustCurrentLibrary
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "SWD\tools\swd_extract.ps1"
   ```
   Copy the resulting CSVs aside before doing anything else.
2. **Restore** `rapports_hydro/` from `%USERPROFILE%\SWD-backup\<date>\`.
3. **Extract again** — captures the 20 m/s reports.
4. **Merge** the two tables on a speed column.

The 13 previously-unscanned boards have nothing to restore; their reports are additive and survive
both passes.

**Never `-AllowUntrustedFiles`.** Re-approve with `-TrustCurrentLibrary` after the scan session — the
friction is the point. `BinaryFormatter` needs **Windows PowerShell 5.1**.

### Verify the merge, by assertion

| Check | Expect |
|---|---|
| Distinct physical speeds | **2** (~10.0 and ~20.0), not 1 |
| Boards carrying both speeds | **13** |
| `scan_speed_ms` recovered | ~10.000 for the new rows — recovered from `ṁ = ρAV`, independently of any setting |
| Parse failures | 0 |
| Polar blocks | 1890 / 1890 |
| Encoding | UTF-8, no BOM; `extract_manifest.json` present as the completion sentinel |

> ### Point of note — the trap to check for
> `board_speed_setting_ms` is **metadata and is not the speed the scan ran at**. All 132 original
> reports were computed at 20.000 m/s while the stored setting varies over 2–20 m/s. Using it as a
> feature trains on a label that does not describe the physics. The physical condition is
> `scan_speed_ms`, recovered from the mass balance. Confirm the new rows the same way, and do not let
> a matching `board_speed_setting_ms` stand in as evidence.

---

## 5. Step 7 — correct the record

| File | Change |
|---|---|
| `SWD/tools/phase2/control-map-scanner-open.csv` | **Rename to `control-map-fins-tab.csv`.** Content-diffed 2026-08-29: it is the Fins tab (`Thruster`, `Quad`, `Twin`, `Fcs`, `Toe angle°`, `Cant angle°`, `Fin technology`) plus three progress bars, with **zero** drift or speed controls |
| every document calling it "the scanner panel" | Fix. Also fix `TODO.md:753`'s *"241 with the scanner panel open, vs 165 closed"* — it and `control-map.csv` have **identical handle sets**, the same enumeration written twice differing only in `Rect`, so the claim is wrong on both halves |
| [`SWD/TODO.md`](../../TODO.md) | Worklist item 1 closed (unfocused send, settled in Step 2); item 2's premise refuted; item 7 done; the per-angle cost model re-based |
| [`SWD/data/coverage.md`](../../data/coverage.md) | Regenerate — two physical speeds, 26 scanned boards, the (speed, radius) table, and the `boards.csv` vs live-app volume discrepancy |
| [`SWD/tools/phase2/RESUME.md`](../../tools/phase2/RESUME.md) | Steps 6–10 |
| [`SWD/docs/phase2-hydroscan.md`](../phase2-hydroscan.md) | § 1 yield table and § 6 guidance |
| `~/.claude/qa-history/swd-phase2.md` | Ledger entry per its § 8 append protocol; close suspects 19 (flaky suite) and 20 (dialog class) if Steps 2 and 4 settled them |
| `~/.claude/qa-history/briefs/` | Efficiency learning brief, if `sqa-efficiency` was dispatched |
| [`CLAUDE.md`](../../../CLAUDE.md) § 9 | Mark WP3 complete |

### What [`coverage.md`](../../data/coverage.md) must say honestly

The corpus will still not establish:

- **Generalisation across boards** — 26 hulls is a small, non-random sample of shapes.
- **Speed dependence beyond two points.** Two speeds show that a dependence *exists*; they cannot
  show its shape. Do not fit a curve through two points and call it a speed model.
- **Absolute accuracy.** These are SWD's model outputs, not experimental measurements. The extraction
  is verified faithful to the files — a different claim from the physics being right.
- **Negative turn radius.** `Jules_egg`, `blueTreck` and `hydroactive_Wake` are the only three
  negative-radius boards in the library, and they are the missing negative-roll side.

Per the project brief: *"a numerical result or visually convincing output is not sufficient
evidence"*, and a partially successful method validated honestly with limitations identified still
earns a strong result. **Never dress up a negative result.**

---

## 6. Standing constraints — [`CLAUDE.md`](../../../CLAUDE.md) § 4, quoted not referenced

- **Never write inside `C:\Program Files\ShaperWaveDynamics\`.**
- **Never modify a file in `biblio\` in place** — deserialise a **copy**.
- **Never construct `Form_shaper` headlessly.**
- **Never `-AllowUntrustedFiles`.**
- **`BinaryFormatter` needs Windows PowerShell 5.1.**
- **Do not accept SWD's advertised 1.1.0.6 upgrade.**
- **Never commit the licence key** — `.gitignore` blocks `*.reg` and `SWD/backup/`.
