# SWD acquisition — progress

Live checklist for the data-acquisition work. Kept current so the job survives
session boundaries; Phase 2 alone spans days of scan time.

> ### ▶️ Picking this up cold? Read [`SWD/tools/phase2/RESUME.md`](tools/phase2/RESUME.md) first.
> Phase 2 was paused mid-fix on 2026-08-27 and **the code in `tools/phase2/` does not
> currently run** - `swd_msg.ps1` was rewritten and its type rename was not propagated to
> `swd_diagnose.ps1`. RESUME.md says exactly what state everything is in and what to do next.

Plans: `~/.claude/plans/do-some-research-to-atomic-sky.md` (WP1 paper data, WP2 metrics doc)
and `~/.claude/plans/coudl-you-open-up-expressive-rose.md` (WP3, Phase 2 — active)

## Backups (outside the repo, deliberately)

`%USERPROFILE%\SWD-backup\20260826\`

Two things changed from the plan, both because this repo gets uploaded:

- **The licence `.reg` is a secret.** `HKLM\SOFTWARE\WOW6432Node\swdy\info` is a
  50-character activation string. It is backed up outside the repo and blocked in
  `.gitignore`. It must never be committed.
- **`biblio\` is 627 MB.** Too large for the repo, and it is licensed vendor data.
  Only the extracted CSVs are committed.

| Item | State |
|---|---|
| `swdy-licence.reg` | ✅ 304 B |
| `user.config` | ✅ 14,224 B |
| `biblio\` mirror | ✅ 374/374 files, 627.1 MB — **verified restorable** (19-file stratified SHA256 sample, 0 mismatches) |

## Checklist

| # | Task | Phase | State |
|---|---|---|---|
| 1 | Export licence key, back up `biblio\` and `user.config` | 0 | ✅ |
| 2 | Scaffold `SWD\{tools,data,docs}\` + `.gitignore` | 0 | ✅ |
| 3 | Write `swd_extract.ps1` | 1 | ✅ |
| 4 | Extract `boards.csv` (27 boards), verify against plan table | 1 | ✅ 27/27, 0 fail |
| 5 | Extract `operating_points.csv` — assert 617 rows, 0 failures | 1 | ✅ 617 rows, 0 fail |
| 6 | Extract `elements.csv` (5,914 rows) and `fin_polars.csv` | 1 | ✅ 5,914 + 340,200 |
| 7 | Spot-check 3 rows against the SWD GUI | 1 | ⏸ deferred — needs the GUI open |
| 8 | **SQA loop on all `SWD\tools\*.ps1` — hard gate** | 1.5 | ✅ 3 rounds + independent verify |
| 9 | Round-trip gate — re-serialise unchanged `.fynbs` copy | 2 | ✅ 59/59 fields identical |
| 10 | Drive one HydroScan end-to-end; verify | 2 | ✅ 2026-08-28, 11 reports, extractor 143/143 |
| 11 | Resolve whether radius is persisted numerically | 2 | ✅ **NO** — per-board, constant in 13/13 |
| 12 | Scan the 15 unscanned boards (~825 new points) | 2 | ⏸ needs item 10 |
| 13 | Re-scan at new speeds beyond 2–20 m/s | 2 | ⏸ needs item 10 |
| 14 | Radius sweep on `.fynbs` copies | 2 | ⏸ needs item 10 |
| 15 | Re-extract; write [`coverage.md`](data/coverage.md) | 3 | ✅ regenerated 2026-08-28 for 667 rows |
| 16 | Write `SWD\README.md` + AI Acknowledgment | 3 | ✅ |
| 17 | Write repo-root [`CLAUDE.md`](../CLAUDE.md) | 4 | ✅ |

Items 1–7 touch nothing but files and complete without launching SWD.
**Item 8 gates everything after it.** Items 9+ drive the GUI.


---

## Finding: the stored board speed is not the scan speed

Caught during Phase 1 validation, and it changes how the dataset must be used.

`_vitesse_flux_relatif_ms` in each `.fynbs` was initially taken to be the speed
its hydroscan ran at. It is not — it is the GUI's speed box as it stood when the
board was last saved.

Evidence, all from the extracted data:

- Recovering flow speed from the planing mass balance `m_dot = rho*A*V` gives
  **20.000 m/s for every one of the 12 scanned boards, with zero variance
  within each board**, while the stored setting ranges over 2–20 m/s.
- `m_dot/A` is exactly `rho*V`, and it takes **two** values corpus-wide:
  **20460.0** (5,461 elements) and **20500.0** (1,404) — i.e. `1023 x 20.000` and
  `1025 x 20.000`. Density is a **4-entry lookup table** recovered by decompiling
  `Form_shaper.actualiser_fluide()`, indexed by `temperature_eau` in {0,10,20,30} degC:
  salt `1028/1027/1025/1023`, fresh `999.87/999.73/998.23/995.67`. It is never computed,
  so rho can only ever be one of eight values.
  *(Corrected 2026-09-01. The "20463.09, std 10.68, implied 1023.154, 0.015% residual"
  account was wrong: it pooled a bimodal mixture, and the "std" was the gap between the
  two modes. Within a single temperature the ratio is reproducible to 7 s.f. — measured
  20460.000 +/- 0.002 on `default_shortboard`. The 2026-08-27 note that "corrected" the
  original "factorises exactly as 1023" reading was itself the error; the original was
  right. Separation between the two groups is 49.8 sigma.)*
- **The "second scan speed" of 20.0391 m/s never existed.** It is `20500/1023` — the
  rho=1025 scans divided by an assumed 1023. After the fix, all **720** operating points
  read 20.000 m/s and `rho_kgm3` is emitted beside them.
- Two near-identical shortboards stored at 20 and 5 m/s (1.74 vs 1.77 kg, both
  straight-line) have a median drag ratio of **1.11x**. V² scaling would require 16x.
- Spearman correlation between the stored setting and drag: **−0.15**.

The extractor now emits both columns under unambiguous names — `scan_speed_ms`
(the physical condition) and `board_speed_setting_ms` (metadata) — and the script
header explains the difference so the CSV cannot be misread later.

**Consequence:** the existing corpus has **one** scan speed, not six. True
coverage is 1 speed x 9 radii, not the 12 (V,R) pairs the board metadata
suggested. Every bit of speed variation must come from new hydroscans in Phase 2,
so that phase is now required rather than an enhancement.

## Extracted so far

| File | Rows | Notes |
|---|---:|---|
| `operating_points.csv` | 617 | training table; 19 cols; 0 NaN in the four channels |
| `elements.csv` | 5,914 | 35 cols; **not** independent samples |
| `boards.csv` | 27 | 12 with hydroscans, 15 without |
| `fin_polars.csv` | 340,200 | Re / angle / Cl / Cd / Cm |

Roll spans −0.798…+1.491 rad per element (target [−π/3, π/3] = [−1.047, 1.047]).
All four required channels are float64 with no missing values.

---

## SQA round 1 — VERDICT: Critical=3 | Warning=5 | Suggestion=19

The gate did its job. Two of the three Criticals are silent data defects that the
run's own "132/132, 0 failures" message was actively concealing — a count of
files that *parsed*, not of data that *arrived*.

**Critical 1 — half the fin-polar database was missing.** `XmlReader.ReadOuterXml()`
leaves the reader on the next node, and with `IgnoreWhitespace = $true` that node
is the next `<Table4>` start element; `ReadToFollowing` then calls `Read()` before
testing and steps straight past it. The XML holds 1,890 blocks, the CSV held 945 —
exactly the even-indexed half. Reported as `polar rows: 340200`, i.e. success.

**Critical 2 — 13 of 28 element columns are identically zero** across all 5,914
rows. Physically self-contradictory: `element_length_mm` is 0 while
`wetted_length_mm` reaches 2,925 mm; `boundary_layer_mm` is 0 while
`drag_friction_n` reaches 883 N. This is the exact fake-zero-column failure the
script header claims to prevent.

**Critical 3 — deferred, needs sign-off.** `BinaryFormatter` runs with no
`SerializationBinder` over a recursive glob of the library. The "these are your own
files" premise turns out to be false: the library carries seven distinct
`shaper_name` values including other people's names, plus a `swdshare` directory.
SWD only deserialises files you explicitly open; this script auto-deserialises
everything in the tree, so a hostile file arriving by OneDrive sync would execute
without being opened. **Not fixed** — security fixes need sign-off. A ready-to-apply
patch is being written to [`SWD/docs/pending-security-fix.md`](docs/pending-security-fix.md).

**Privacy (Warning 5).** The repo has a live public remote
(`github.com/benmoors/hydrodynamics-fin`), `boards.csv` is not gitignored, and
`.gitignore` says extracted CSVs are meant to be committed. One `git add -A` would
publish six other people's names. Verified **nothing from `SWD/` is committed yet**,
so this is not yet realised. Fixed in round 1 — `shaper_name` dropped; it was never an ML feature.

**What the invariants review found.** The containment concern that motivated the
gate came back clean: every write resolves inside the output directory (exactly two
write sinks in the file), zero paths reach `C:\Program Files\`, the library is
opened `FileAccess::Read`, the registry is never touched, no `Form_shaper` and no DX
device, and handles are disposed on every path including exceptions. One correction:
`SlimDX.dll` is a mixed-mode image, so its native `DllMain` does run on load — it
just doesn't create a device. The header wording is being corrected.

---

## SQA round 1 — fixer result (claims, pending independent verification)

Fixer verdict: `Critical=1 | Warning=0 | Suggestion=4`. The remaining Critical is the
security item it was told not to apply. A **fresh** SQA instance is verifying now —
an agent never certifies its own fixes.

| Finding | Outcome |
|---|---|
| C1 half the fin-polar DB missing | fixed — `fin_polars.csv` **340,200 → 680,400 rows**, with a permanent `1890/1890` block assertion |
| C2 13 fake-zero columns | fixed — constant-zero columns detected and dropped by name at write time |
| C3 unrestricted `BinaryFormatter` | **NOT APPLIED — awaiting sign-off**, patch in [`SWD/docs/pending-security-fix.md`](docs/pending-security-fix.md) |
| W1 unconstrained `-OutDir` | fixed — anchored to `$PWD.ProviderPath`, refuses a path inside the install or library trees |
| W2 board null → `0.0` | fixed — absent *and* null now map to `NaN` |
| W3 board name from fixed parent hop | fixed — first segment under `rapports_hydro`, warns on lookup miss |
| W4 mixed-vintage CSV set | fixed — all four written together, `extract_manifest.json` last as a completion sentinel |
| W5 third-party names in a git tree | fixed — `shaper_name` dropped |

**The recovered half of the polar database was not redundant.** It contained
**1 profile and 23 Reynolds numbers that appeared nowhere in the data before** —
134 profiles vs 133, 104 Reynolds values vs 81. Had this shipped, a third of the
Reynolds coverage would have been silently missing.

**C2's root cause is now settled**, and it is not what the header assumed. All 13
zero columns are on the *serialised* side and are `System.Single` — a value type that
can never be null — so the original "checked to be genuinely serialised" test was
literally true and still insufficient. The second failure mode is a serialised field
that SWD's hydroscan path simply never assigns, which deserialises to a real `0.0f`.
Null-checking cannot catch that; only a constant-column check can.

Also done this round: 100 Pester tests written where there were none (relocated from
a session-scoped scratchpad into `SWD/tools/tests/`, re-run from the new location:
**100 passed, 0 failed**), and the pre-fix script archived to
`%USERPROFILE%\SWD-backup\20260826\pre-sqa-fix\`.

## ~~⚠️ ONE DECISION WAITING ON YOU~~ — RESOLVED 2026-08-27, gate applied

[`SWD/docs/pending-security-fix.md`](docs/pending-security-fix.md) — whether to apply the `BinaryFormatter`
provenance gate. Its own recommendation is **Layer A only** (~40 lines, refuses to
deserialise any `.fyn*` whose SHA-256 is not in a manifest you approved once; no
change to extracted data). Layer B, a type allowlist, is written up but not
recommended — a missed type turns into a silent counted parse failure.

One practical note the document raises: Layer A would refuse every newly generated
`.fynrhydro` after each Phase 2 hydroscan. Scoping the gate to `Boards/` and leaving
`rapports_hydro/` open matches the actual threat, since traded board files are the
untrusted input and hydroscan outputs are produced locally by SWD.

---

## SQA round 3 — fixer result (claims, final verification running)

Fixer verdict: `Critical=1 | Warning=0 | Suggestion=5`. The single Critical is the
parked `BinaryFormatter` item still awaiting sign-off.

| Round-2 finding | Outcome |
|---|---|
| **C** containment missed parent directories | fixed — `Get-ProtectedRoot` now covers each path *and* its parent, drive roots excluded |
| W1 lexical vs canonical paths | fixed — `\` prefixes refused outright; 8.3 names and junctions collapsed via `GetFinalPathNameByHandle` |
| W2 StrictMode crash on empty corpus | fixed at root — member enumeration replaced, StrictMode kept |
| W3 `-SkipElements` stale-table sentinel | fixed — manifest built only from tables actually written; unwritten outputs deleted |
| W4 manifest leaked username + tenant | fixed — absolute paths and tenant removed |

Reported: 133 Pester tests passing (up from 100), mutation 26/26 with **22 now
behavioural** where C1 previously had none, all four tables regenerated
byte-identically across two runs.

**Three self-corrections the fixer made, which matter more than the fixes.**

1. **The −7.9% performance figure is withdrawn as unmeasurable.** The C1 fix changed
   what the program computes — 680,400 rows instead of 340,200 — so the baseline the
   A/B rested on no longer describes the same computation. Restated as *no delta*. The
   `-SkipElements` claim survives because it is structural (10 of 28 fields read,
   byte-identical output), not a timing claim.
2. **Its `swdshare` rebuttal was wrong.** The directory does exist, with 29 `ctr*`
   subdirectories, as a *sibling* of `biblio` — its search had been pointed only at
   `biblio\` and Program Files and then described as covering the documents root. The
   conclusion survives (extensionless files, so the globs never reach it), and
   `swdshare` now sits inside the tree the containment fix protects.
3. **A fixture bug in its own tests, dating from round 1.** PowerShell binds `,` tighter
   than `+`, so `@("aile" + [char]0xE9 + "ron", ...)` was a single 19-character string —
   the "three non-ASCII profile names" fixture had been exercising one mangled name all
   along, and no assertion had ever read a profile value back.

## ⚠️ DECISION STILL OPEN

The `board` column still carries designer and model names — `Bruce Iron Brewer Gun`,
`Laser_Zap_Ben_Aipa`, `DanielThomson_ModernPlaningHull`. Deliberately **not** changed,
because it is the join key across all three tables, so hashing or dropping it is an
observable format change. It is also a weaker case than `shaper_name` was: these are
largely published board *models*, not the file author's name. Your call.

## Known usability trade-off

Parent protection can now refuse a legitimate `-OutDir`. With the default
`-BiblioPath …\ShaperWaveDynamics documents\biblio`, the whole
`…\ShaperWaveDynamics documents` tree is protected. Fail-safe, and the error names the
exact root that fired, but worth knowing before it surprises you.

---

## Final verification + close-out — gate PASSED

Independent round-3 verifier: `Critical=1 | Warning=3 | Suggestion=5`, with an explicit
**ship the dataset / do not rerun the script with non-default paths** split.

Its Critical was a genuine hole in the guard the loop itself had added: `-OutDir`
containment could be silently disabled by the *spelling* of `-BiblioPath`. Line 110
validated the roots with `Test-Path -LiteralPath` (which resolves `~` and relative-against-
`$PWD`) while `Get-ProtectedRoot` recomputed them with bare `[IO.Path]::GetFullPath`
(which resolves neither). A `~`-spelled library path validated as real and then produced a
protected root pointing at a directory that does not exist, so both the lexical and canonical
tests missed. Measured: `GetFullPath('~\x')` returns `<cwd>\~\x`. The verifier demonstrated
it live by deleting a decoy file inside a stand-in library.

**Fixed and verified** (one narrow hunk — both roots now resolve through `Convert-Path`, the
same provider that validated them, and an unresolvable root refuses rather than proceeds):

| Case | Before | After |
|---|---|---|
| tilde `-BiblioPath`, `-OutDir` inside library | **ACCEPTED** | GUARD refused |
| relative `-BiblioPath`, `-OutDir` inside library | **ACCEPTED** | GUARD refused |
| absolute, `-OutDir` inside library / at either parent | refused | refused |
| tilde `-BiblioPath`, `-OutDir` outside any root | — | passes guard (discriminating control) |

Decoy file intact, zero stray directories in either protected tree.

Also closed: the two unredacted console paths (`Format-PathForDisplay` moved above its first
use — PowerShell executes top-down, so the call at :110 would otherwise have failed), and the
two defects the verifier found *inside the parked security patch*, now carried as a warning
banner on that document so it cannot be pasted and run.

### One test-harness trap worth remembering

My first containment harness reported all six cases as failures, including the control that
should have passed. `Start-Process -ArgumentList` builds a single command line, so a sandbox
path containing a space split into positional parameters and the script died **before the
guard ran** — a failure that reads exactly like a successful refusal. Quoting every argument
was the fix. This is the second time this exact trap has appeared in this loop.

### Final state

- 27/27 boards, 132/132 reports, **0 parse failures**, `polar blocks: 1890 / 1890`
- All five CSVs **byte-identical** before and after the containment fix — it changed control
  flow, never data
- Pester **133 passed / 0 failed**; mutation 26/26, 22 behavioural
- No BOM anywhere; zero identifying strings across all of `SWD/data/`, including the 47 MB CSV

### Outstanding, deliberately

1. **[`SWD/docs/pending-security-fix.md`](docs/pending-security-fix.md)** — still needs your sign-off, and now needs its own
   two defects fixed first.
2. **The `board` join key** carries designer/model names — your call, it is the key across all
   three tables.
3. **`fin_polars.csv` is 47 MB.** Under GitHub's 50 MB warning, but it enters history on the
   first commit and is regenerable in ~80 seconds. Consider gitignoring it.
4. **Source-level identifiers**: the tenant literal in `swd_extract.ps1`'s default `-BiblioPath`,
   and absolute user paths in the two test files. In the *source*, not the data.
5. **Phase 2 (items 9-14) is untouched** and stays held until you are back.

---

## Provenance gate APPLIED — 2026-08-27

Layer A applied, both defects in the proposed patch fixed first. Layer B still not
applied, for the reasons in [`SWD/docs/provenance-gate.md`](docs/provenance-gate.md) § 6.

**Defect 1** (patch added a write target outside containment) closed by putting
`-TrustManifest` through the same treatment as `-OutDir`: `$PWD` anchoring, `\`
refusal, canonicalisation, `Test-PathUnderRoot`. All three protected targets now
refused; nothing created in either tree.

**Defect 2** (patch reintroduced the username/tenant leak) closed twice over: the
manifest defaults to `%LOCALAPPDATA%\swd-extract\`, outside the repo so it cannot be
committed, and stores only library-relative paths plus hashes. The 372-entry manifest
contains no username, no tenant, no `C:\`.

### Verified by running, not reasoning

| Check | Result |
|---|---|
| Cold run, no manifest | all 159 files refused, tables reported INCOMPLETE |
| Approve then run | 27/27 boards, 132/132 reports, 1890/1890 polar blocks |
| All four CSVs before vs after | **byte-identical** |
| Tampered file (1 byte, same path and length) | refused by name |
| Valid but never-approved file arrives | refused by name; after approval, parses |
| `-TrustManifest` into install / library / library parent | all refused |
| Pester | 133 passed, 0 failed |

### Two things to know before relying on it

1. **Trust-on-first-use.** The 2026-08-27 baseline blesses the 372 files as they stood.
   It detects *change* and *new arrivals* after that point; it does not validate the
   baseline. It does not make `BinaryFormatter` safe either — a hostile file built from
   approved hashes is still deserialised.
2. **Phase 2 friction is deliberate.** Each hydroscan writes new `.fynrhydro` files that
   the gate refuses until approved, so re-run `-TrustCurrentLibrary` after each scan
   session. That converts "a file appeared and was executed" into "a file appeared and
   someone decided". Do not use `-AllowUntrustedFiles` to dodge it.

### The lesson worth keeping

The proposed patch was written in round 1 and reviewed as an artifact in round 3 — by
which time the containment and privacy invariants it violated had been added in rounds
2 and 3. Neither defect was visible reading the patch on its own terms; both appeared
immediately when it was checked against invariants that post-dated it. A parked patch
ages against a moving codebase, and nothing re-checks it automatically.

---

## Phases 3 and 4 complete — 2026-08-27

**Phase 2 is parked, not dropped.** Item 9 (the round-trip gate) passed: 59 of 59 serialised
scalars identical, so writing modified board copies is proven safe. Item 10 is blocked by an
OS-level input block on this machine, diagnosed in [`docs/phase2-hydroscan.md`](docs/phase2-hydroscan.md). Everything needed
to resume is written down, including the two coordinate bugs that were found and fixed along the
way and the working GUI helper at `tools/phase2/swd_ui.ps1`.

### Delivered

| Item | Where |
|---|---|
| Project documentation to the brief's seven sections | [`SWD/README.md`](README.md) |
| Provenance gate design, verification and limits | [`SWD/docs/provenance-gate.md`](docs/provenance-gate.md) |
| Phase 2 findings, blocker diagnosis, resume steps | [`SWD/docs/phase2-hydroscan.md`](docs/phase2-hydroscan.md) |
| Dataset coverage with artefacts named | [`SWD/data/coverage.md`](data/coverage.md) |
| Standing instructions for future sessions | repo-root [`CLAUDE.md`](../CLAUDE.md) |

### A note on the sentinel, which earned its place

Before writing the documentation the data directory was found to be **missing
`extract_manifest.json`** while all four CSVs looked complete and correct. By the sentinel's own
contract that set was unvouched, so it was regenerated rather than documented. The regenerated
CSVs came back byte-identical, so nothing was actually wrong with the data — but that could not
have been known in advance, which is the whole point. Without the sentinel the set would have
been shipped on the strength of looking right.

### Documentation style pass

[`SWD/README.md`](README.md) had a `humanizer` pass applied, with the fact-preservation check the protocol
requires: **95 of 95 numbers, 4 of 4 paths, 3 of 3 commands and 32 of 32 code identifiers survived
unchanged**, all 22 em dashes, 19 emoji headings and 24 tables intact, and the
`## 🤖 AI Acknowledgment` section byte-identical (it is graded and is never style-edited). Net
change was 230 characters of tightening.

### Still open, both yours to call

1. **The `board` join key carries designer and model names** (`Bruce Iron Brewer Gun`,
   `DanielThomson_ModernPlaningHull`). It is the join key across all three tables, so hashing or
   dropping it is an observable format change. These read as published board models rather than a
   file author's name, which is a weaker case than `shaper_name` was.
2. **`fin_polars.csv` is 48.3 MB** and regenerates in ~80 seconds. Under GitHub's 50 MB warning,
   but it enters history permanently on the first commit. Worth gitignoring unless you want it
   version-controlled.

---

## Phase 2 — automation rebuilt for a headless route, 2026-08-27

Item 10 is being unblocked. Two contradictory diagnoses of the original failure were on record;
rather than pick one, the new code measures which is right. Full production record in
[`SWD/tools/phase2/BUILD-NOTES.md`](tools/phase2/BUILD-NOTES.md).

| File | Role |
|---|---|
| `tools/phase2/swd_msg.ps1` | **new** — drives SWD by `BM_CLICK`/`WM_SETTEXT` straight to control handles. No cursor, no focus, so SWD can sit minimised |
| `tools/phase2/swd_diagnose.ps1` | **new** — step 0. Compares integrity levels, re-tests the input block, dumps the UIA tree and every child window, and probes whether an unfocused click lands |
| `tools/phase2/swd_ui.ps1` | unchanged — the cursor/UIA layer, now the fallback |

**Why headless became the point.** Scans run for minutes and must not take the machine over. The
message route is headless by construction; the one thing between that and a guarantee is Microsoft's
documented caveat that `BM_CLICK` *"might fail"* on a button in a dialog that is not active.
`swd_diagnose.ps1 -ClickProbe` measures it on a harmless control before the scan path depends on it.

**Verified so far, and no further:** both scripts parse under PowerShell 7.6.5 **and** Windows
PowerShell 5.1 (5.1 is required — section D loads `UIAutomationClient`, a .NET Framework assembly);
PSScriptAnalyzer 1.25.0 reports **0 Error/Warning in new code**; three InjectionHunter findings
assessed, one hardened, two documented as false positives.

**Not verified: any of it against SWD.** Nothing has run. The 165-child-window figure comes from the
plan's narrative, not from a run here. No Pester tests yet, against `swd_extract.ps1`'s 133.

**The unit trap now encoded:** the speed boxes are `NumericUpDownScanSpeed{1,2,3}kmh` — **km/h** —
while the whole project works in m/s. 20 m/s = 72 km/h; the 10 m/s verification target = 36 km/h.
`ConvertTo-Kmh` exists so nobody types the m/s number into a km/h box and gets a plausible wrong scan.

**Privacy:** `control-map.csv` and `logs/` are gitignored. They carry `WM_GETTEXT` output from every
control plus window renders, either of which can hold the library path (username, tenant) or designer
names — the leak class round 1 closed by dropping `shaper_name`.

### Tonight's run — ordered checklist

Decided 2026-08-27: the read-only diagnostic runs ahead of the SQA pass, because it sends no
state-changing message. **The SQA pass sits at step 5 — before the first click, before any scan.**
One run, not a full loop.

| # | Step | Who | State |
|---|---|---|---|
| 1 | Diagnostic, non-elevated, SWD closed — host + input-block baseline | script | ✅ 12:02, see below |
| 2 | **Launch SWD by hand and watch for a UAC prompt** | you | ✅ no prompt seen - superseded by the token measurement |
| 3 | Diagnostic, non-elevated, SWD running — the "before" half of the comparison | script | ✅ 12:11 |
| 4 | Diagnostic, **elevated** — the "after" half; writes `control-map.csv` | you launch, script runs | ✅ 12:13 |
| 5 | **SQA pass — ONE run, not a loop** — `swd_msg.ps1` + `swd_diagnose.ps1` | sqa-lead | ✅ `C=6 / W=11 / S=14` → [`SQA-FINDINGS.md`](tools/phase2/SQA-FINDINGS.md) |
| 5b | **3-round SQA loop** — fix + independent verify ×3 | code-reviewer / fresh sqa-lead | ✅ closed at cap, **`C=0 W=7 S=11`** |
| 6 | `-ClickProbe <handle>` on a harmless control — settles the headless question | script | ⬜ |
| 7 | Write the scan driver (`swd_scan.ps1`) — **needs a SECOND control map taken with the scanner panel open** | — | ⬜ |
| 8 | Verification scan: 1 unscanned board, 3 drift angles, **36 km/h = 10 m/s** | script | ⬜ |
| 9 | `-TrustCurrentLibrary`, re-extract, check recovered `scan_speed_ms` is 10.000 not 20.000 | script | ⬜ |
| 10 | Answer the radius-persistence question; rewrite [`docs/phase2-hydroscan.md`](docs/phase2-hydroscan.md) §§ 3, 5 | — | ⬜ |

Step 2 is the one no script can do: **whether SWD raises a UAC prompt decides the whole diagnosis**,
and only a person watching the screen can see it.

Step 5 is placed after step 4 deliberately — by then `control-map.csv` exists, so the review reads
against the real control set rather than against the plan's narrative.

### Step 1 result — one diagnosis partly refuted

| Measurement | Result |
|---|---|
| Host | Windows PowerShell 5.1.26100.9168, **not elevated**, Medium integrity |
| `SetCursorPos` | `True`, lastError 0 |
| **Cursor actually landed** | **`True`** — asked (1026,730), got (1026,730) |
| `BlockInput(false)` | `False`, **lastError 5** |

**There is no input block now.** [`docs/phase2-hydroscan.md`](docs/phase2-hydroscan.md) § 5 treated
`BlockInput(false) → ERROR_ACCESS_DENIED` as proof that *"another process holds an input block"*. That
same error appears here while the cursor moves freely, so the inference does not hold — error 5 is
just what a non-elevated caller gets. Whether an elevated call returns `True` is a step-4 check.

This does **not** say there was no block on 26 August: `SetCursorPos` returning `False` then was real
and is still unexplained. It says one of the two pieces of evidence for it was worthless.

### Two traps found by running, both fixed

- **`[CmdletBinding()]` empties `$PSScriptRoot` inside `param()` defaults** on Windows PowerShell 5.1.
  Remove the attribute and the same default works. Isolated by bisection; the help block and the
  relative-vs-absolute `-File` path were ruled out first. Killed `swd_diagnose.ps1` on its own first
  line.
- **`$PSScriptRoot` inside a function resolves at *call* time**, pointing at the calling script.
  `Save-SwdWindowImage` would have written PNGs beside whoever dot-sourced it. Captured at load time
  as `$script:SwdMsgRoot` instead.


### Steps 3-4 result - UIPI confirmed, one variable changed

Same SWD process (pid 42488) for both runs; only the shell's elevation differed.

| | Non-elevated | Elevated |
|---|---|---|
| This shell | Medium `S-1-16-8192` | High `S-1-16-12288` |
| SWD | **UNREADABLE** (token access denied) | High `S-1-16-12288` |
| UIA descendants | **98, all bare `Pane`** | **131, named** - 15 Button, 8 MenuItem, 16 Text, 6 Group, 2 ComboBox... |
| `BlockInput(false)` | `False`, lastError 5 | `False`, lastError **0** |

[`docs/phase2-hydroscan.md`](docs/phase2-hydroscan.md) section 5 is wrong on both of its load-bearing claims and needs the
rewrite at step 10. **The fix is elevation**, exactly as the WP3 plan predicted.

**Unexpected, and useful: reads cross the boundary.** `EnumChildWindows` + `WM_GETTEXT` returned real
text for all 181 controls from the Medium shell. UIPI filters state-changing messages, so `BM_CLICK`
and `WM_SETTEXT` should fail unelevated and succeed elevated - running the step-6 probe from *both*
shells would prove it in one pair of measurements rather than assuming it.

**Blocking finding for step 7:** the scan parameter controls do not exist yet. One `msctls_updown32`
in the whole app and nothing mentioning drift or speed - the panel is built on demand, and the app
says so itself (*"No HydroScan for this board... Use the Scaner tool"*). The control map is
two-stage, and the scan driver cannot be written against the current one.

Located: **`Hydrodynamics Scanner`, handle `19726830`**, enabled. Title still reads `<no Wave>` - the
open question about a wave being a precondition is untouched.

### Two more defects found by running, both fixed

1. **Log was UTF-16LE with a BOM** (`ff fe 53 00`) - `Tee-Object` under PowerShell 5.1. This is the
   trap [`CLAUDE.md`](../CLAUDE.md) section 5 already records for CSVs. Now `[IO.File]::AppendAllText` with
   `UTF8Encoding($false)`; re-measured `53 57 44 20`, UTF-8 no BOM.
2. **Section A contradicted section B in the same report** - `WindowsIdentity.Groups` said
   "Medium-or-lower" where the token query said High. A gets its answer from the token now; both
   agree on a fresh run.


---

## Paused 2026-08-27 ~12:40

Stopped mid-fix. **[`SWD/tools/phase2/RESUME.md`](tools/phase2/RESUME.md) is the entry point** for picking this up cold.

### What happened after the SQA pass

The verdict was `Critical=6 | Warning=11 | Suggestion=14` - not clean, and five of the six Criticals
were instruments reporting a state they never achieved or never measured. The most consequential:
**step 6's click probe as written could not be trusted.** It would have printed "THE CLICK LANDED
WITHOUT FOCUS" from a run in which every read timed out, and its `BM_GETCHECK` detector is blind on
`FlatStyle=Standard` WinForms controls - which is what SWD is made of. The one measurement the
headless route rests on would have returned a confident wrong answer.

I began hand-fixing rather than delegating to `code-reviewer`, which was the wrong call: CLAUDE.md's
division of labour makes the reviewer the only agent that edits, and its intake mode obliges it to
address *every* finding rather than the six I had picked. Handed over, then cancelled a minute later
before it had read anything.

### State left behind

| | |
|---|---|
| `swd_msg.ps1` | **Rewritten, UNVERIFIED.** 496 lines, parses, never executed. Type renamed `W` to `SwdWin` |
| `swd_diagnose.ps1` | **Pre-fix.** 331 lines. Still calls `[W]::` in 15 places - **the pair does not run** |
| [`SQA-FINDINGS.md`](tools/phase2/SQA-FINDINGS.md) | New. All 32 findings verbatim - **the only copy**, the agent could not write to disk |
| [`RESUME.md`](tools/phase2/RESUME.md) | New. Entry point for a cold session |
| [`docs/phase2-hydroscan.md`](docs/phase2-hydroscan.md) | Rewritten - sections 3 and 5 were teaching a refuted diagnosis |
| `.gitignore` | `*.log` and `*.png` rules added under `phase2/**` (findings W15b, W16), verified with `git check-ignore` |
| [`BUILD-NOTES.md`](tools/phase2/BUILD-NOTES.md) section 4 | Stale token counts and InjectionHunter line numbers corrected (finding S32) |

The break is loud, not silent: running the diagnostic fails with `Unable to find type [W]`. Nothing
is at risk, but do not expect it to work until 5b is done.

### Closed while pausing

**The ACL escalation does not fire.** SQA flagged that if `BUILTIN\Users` or `Everyone` held write on
`tools/phase2/`, a Medium-integrity replacement of `swd_msg.ps1` before an elevated run would be a
genuine privilege escalation and that finding became Critical. Measured with `icacls`: only
`NT AUTHORITY\SYSTEM`, `BUILTIN\Administrators` and `BENMOORS\moors` hold `(F)`. It stays a Warning.


---

## QA loop CLOSED - 2026-08-28

Three fix rounds, each independently verified by a fresh `sqa-lead`. Closed at the 3-round cap.

| Stage | Verdict |
|---|---|
| Intake audit (full fan-out) | `C=6 W=11 S=14` |
| R1 fix -> R1 verify | `C=0 W=0 S=2` -> **`C=1 W=4 S=8`** |
| R2 fix -> R2 verify | `C=0 W=0 S=4` -> **`C=1 W=2 S=5`** |
| R3 fix -> final verify | `C=0 W=0 S=3` -> **`C=0 W=7 S=11`** |

**Twice a fixer reported clean and a fresh verifier immediately found a Critical.** That is why the
verifier is never the author.

Tests 0 -> **180** (162 + 18), Pester 6.1.0. PSScriptAnalyzer clean on all four files under
Windows PowerShell 5.1 *and* pwsh 7.6.5.

**Ledger:** `~/.claude/qa-history/swd-phase2.md` - 13 standing suspects, 5 process lessons.
**Brief:** `~/.claude/qa-history/briefs/swd-phase2-2026-08-28.md`.
**Staging:** `~/.claude/qa-backups/20260827-193428-swd-phase2/` - 5 snapshots.

### The four defects worth remembering

1. **`-WhatIf` clicked the live application.** `Invoke-SwdButton` lacked `SupportsShouldProcess`
   while both siblings had it and the file asserted the rehearsal contract twice in its own comments.
2. **8.3 short names defeated the path guard.** `C:\Program Files\SHAPER~1\logs` was ALLOWED - a
   section 4 non-negotiable - because a property measured on `GetFullPath` was *assumed* of its
   replacement `GetUnresolvedProviderPathFromPSPath`. Third occurrence of the path-canonicalisation
   class in this project; fixed by **porting** `swd_extract.ps1`'s `GetFinalPathNameByHandleW`
   ancestor-walk rather than writing a fourth resolver.
3. **`New-Item` has no `-LiteralPath`** in either host. The diagnostic threw before section A on any
   first run into a non-existent log directory. Hidden for two rounds because every smoke test
   pre-created one; found only once end-to-end tests existed.
4. **The guard's own guard failed.** `Test-SwdWritableTarget` did not protect the real library -
   Documents is redirected to OneDrive, matching none of its four candidate paths.

### Fitness judgement (from the final verifier, not the author)

- **Run the read-only diagnostic** - guard proven across 34 adversarial spellings, install intact
  after three rounds of tests that deliberately attempt the forbidden write.
- **Run ONE `-ClickProbe`**, under four conditions: fresh handle from a newly generated
  `control-map.csv`; a control whose *caption* changes, never a checkbox; never the scan button; and
  **do not trust the "WITHOUT FOCUS" line** - hand-check it against the logged foreground handles
  until suspect 1 is fixed.
- **Do NOT write the scan driver yet.** `Invoke-SwdButton` and `Set-SwdNumeric` have never executed
  against SWD, and the scan parameter controls do not exist until the scanner panel opens.

**All remaining risk is in the "reports a conclusion it did not measure" class, not the "damages the
installation" class.**


---

## Step 7 requirement discovered live - 2026-08-28

**The scan button raises a MODAL CONFIRMATION, and the tooling cannot see it.**

Measured on the first real click: `Hydrodynamics Scanner` opens a dialog reading roughly *"HydroScan
can take more than 60 mn - do you want to proceed"*, and the scan does not start until OK is pressed.
(The app's own 60-minute figure is wrong, but so was our own estimate: file timestamps on the
existing scans suggested 12-21 min / ~95 s per angle, while a scan driven and timed end to end on
2026-08-28 took **~30 minutes for 11 angles, about 163 s each**. Use 163 s.)

**Requirement: the driver must dismiss this itself. No human clicks.**

Two concrete gaps to close before step 7:

1. **`Get-SwdControl` cannot see it.** It walks `EnumChildWindows` from SWD's MAIN window handle. A
   modal dialog is a **separate top-level window** owned by the process, so it is invisible to the
   whole current toolchain. Needs an `EnumWindows`-by-PID enumerator that finds owned top-level
   windows, then enumerates that dialog's children to locate its OK button.
   A read-only prototype exists in the session scratchpad (`find_dialog.ps1`) - not run, not
   reviewed, and NOT part of the tree.
2. **A sent `BM_CLICK` blocks for the dialog's lifetime.** Measured: `SendMessageTimeout` returned
   `lastError=1460` (`ERROR_TIMEOUT`) because the modal blocked SWD's message pump. The click had
   **landed**; only the acknowledgement could not return inside the 5 s budget. So the driver must
   use `-Post` for anything that can raise a dialog, then poll for the dialog to appear.

**Also a finding against the diagnostic:** section F prints *"THE SEND FAILED, lastError=1460.
Nothing was measured"* for this case. Defensible in isolation, but wrong here - the send timed out
because the click succeeded and opened a modal.

**CORRECTED 2026-08-28 after SQA measured it.** `1460` is **AMBIGUOUS**, not "probably landed". Two
sends to a control whose UI thread was blocked both returned `1460` and the target's click counter
read **0** - neither landed. The favourable case gives the identical code, so the two are
indistinguishable from the return value alone. Replacing one confident reading with the opposite one
would have been the same mistake. Observe instead: poll for a dialog, check the target's state.

**Sequencing note:** this is new `.ps1` touching SWD, so [`CLAUDE.md`](../CLAUDE.md) section 4 puts it through an SQA
pass before it runs against the real installation - same gate the message layer went through.


---

## First driven hydroscan - results, 2026-08-28

Scan ran 05:11:22 -> 05:41:04 on `default_shortboard_Copy_1`, 11 drift angles (0-90 deg).
Trust manifest re-approved (372 -> 383 files), full re-extract clean.

| | Before | After |
|---|---:|---:|
| Reports | 132 | **143** (0 parse failures) |
| Operating points | 617 | **667** |
| Element rows | 5,914 | **6,388** |
| Polar blocks | 1890/1890 | 1890/1890 |
| Scanned boards | 12 | **13** |

### The question it answered: turn radius is PER-BOARD, permanently

`turn_radius_m` is constant within **13 of 13** scanned boards, including the one we drove and
watched - 50 operating points across 11 drift angles, all carrying 100000 m. So the `Single[]` that
`Create_Chart_scan_radius` takes never reaches disk per operating point.

**Consequence:** radius is board metadata, not a per-point feature. Training `(V, phi) -> R` teaches
board recognition. The earlier "0 of 12 vary internally" was a property of the format, not a thin
corpus.

### What it did NOT do

**It did not touch the speed axis.** Recovered `scan_speed_ms` = 20.0391 - the same single condition
as all 132 earlier reports. Phase 2's actual purpose is untouched.

### Two provenance findings

1. **The board was homothetically scaled mid-session**, 1800 -> 2000 mm. Measured: +20.6% mass,
   +41.7% volume vs its siblings; a uniform 1.111x scale gives 1.111^3 = +37%, which matches, while
   length alone would give +11%. Data is internally consistent, but `default_shortboard_Copy_1` is no
   longer a copy of the default shortboard and must not be described as one.
2. **`default_shortboard_Copy_2` is a geometric duplicate** of the already-scanned Copy_3, identical
   to full float precision. 27 boards, **26 distinct geometries**. Skip it in any batch - it costs
   ~30 min and adds pseudo-replication, not information.

### Cost model corrected

Timestamps on old scans implied 12-21 min per board (~95 s/angle). **Measured end to end: ~30 min for
11 angles, ~163 s each.** Every estimate built on 95 s was ~1.7x too cheap. The 13 distinct unscanned
boards are **~6 hours**, not ~4. Corrected in [`docs/phase2-hydroscan.md`](docs/phase2-hydroscan.md), [`README.md`](README.md) and above.

### New extractor warning, recorded not suppressed

Per-element scan speeds disagree beyond 6 s.f. in **1 of 667** operating points (worst relative
spread 1.555e-06). Negligible for modelling, but the median is no longer merely "the representative
value" for that row.


---

## ACTIVE WORKLIST - 2026-08-28

Ordered. Items 1-2 need SWD open with the scanner panel showing; everything below that is code.

| # | Task | Needs | Est. | State |
|---|---|---|---|---|
| 1 | **Unfocused click probe** - the headless claim is still an inference | SWD open, NOT focused | 2 min | ⬜ |
| 2 | ~~**Identify the scan parameter controls** in the 241-control scanner-open map~~ | - | - | ❌ **PREMISE REFUTED 2026-08-29 - see below.** Superseded by [`docs/plans/WP3-STEP-0-3-verification-scan.md`](docs/plans/WP3-STEP-0-3-verification-scan.md) Step 0 |
| 3 | **Modal-dialog handling** - `EnumWindows`-by-PID so the driver dismisses the confirmation itself | code | done | ✅ built, 11 tests, SQA running |
| 4 | Fix `lastError=1460` misreported as "THE SEND FAILED" | code | done | ✅ |
| 5 | Fix QA Warning 1 - `$heldFocus` compares a cached `MainWindowHandle` | code | done | ✅ now tests the owning PROCESS |
| 6 | **Scan driver** `swd_scan.ps1` | needs 2, 3 | 2-3 h + SQA | ⬜ |
| 7 | **Speed-axis scans** - the actual Phase 2 goal | needs 6 | ~6 h scanning | ⬜ |
| 8 | Capture `boards.csv` before AND after the next scan | - | 1 min | ⬜ |

### Why item 1 is first

Everything about "the scan can run while the machine is used" is still an **inference**. An elevated
`BM_CLICK` demonstrably actuated the real scan button, but SWD **held focus** at that moment, so the
unfocused case has never been shown on the real application. One probe on a harmless visible control,
SWD unfocused, settles it. If it fails, route 2 (`tscon`, detached session) applies and the whole
headless premise changes.

### Why item 8 exists

`default_shortboard_Copy_1` is +20.6% mass and +41.7% volume against its siblings at the **same
1800 mm length**, and the cause is unknown - see [`data/coverage.md`](data/coverage.md). No pre-scan `boards.csv` survives
to compare against, because the data directory is regenerated in place and `SWD/` is untracked. One
`cp` before the next scan makes the next occurrence answerable.

### Preserved artefact

> **⚠️ WRONG ON BOTH HALVES - measured 2026-08-29. Do not act on the paragraph below.**
>
> **It is the FINS TAB, not the scanner panel.** Content-diffed against a live 166-control map,
> its extra controls are `Thruster`, `Quad`, `Twin`, `Fcs`, `Fcs2`, `Future 1/2 (center)`,
> `Us Box`, `Toe angle°`, `Cant angle°`, `Fin technology`, `Selected Fin Name:` plus three
> `msctls_progress32` bars. It contains **zero** drift or speed controls, so worklist item 2
> cannot be completed from it.
>
> **And "vs 165 closed" is also wrong:** this file and `control-map.csv` have **identical
> handle sets** - the same enumeration written twice, differing only in `Rect`. There is no
> closed-versus-open pair here at all.
>
> Scheduled for rename to `control-map-fins-tab.csv` in Step 7.

`tools/phase2/control-map-scanner-open.csv` - 241 controls with the scanner panel open, vs 165 closed.
It exists only while that panel is open, so it was copied before the next diagnostic run overwrote it.
Gitignored (the rule was widened from the path-literal `control-map.csv` to `control-map*.csv` -
the same path-literal weakness the SQA loop raised twice).

### Not on this list, deliberately

The 7 QA warnings other than Warning 1: all test-adequacy, none blocking. The metric loop
(mutation score): skipped by decision, recorded in the ledger.

---

## Modal dialog layer built - 2026-08-28

Worklist items 3, 4 and 5, one change set, one SQA pass (running).

| | |
|---|---|
| `swd_msg.ps1` | + `SwdWin.EnumWindows` / `TopLevelForPid`, `Get-SwdDialog`, `Get-SwdDialogControl`, `Wait-SwdDialog`, `Invoke-SwdDialogButton`, `Format-SwdSendError` |
| `swd_diagnose.ps1` | 1460 branch rewritten; `Test-SwdOwnsForeground` replaces the cached-handle focus test |
| `tests/swd_msg.Tests.ps1` | +11 tests (162 -> 173), incl. a second-top-level-window harness |
| Guard | **Pester 191/191**, 0 failed, 0 skipped; PSSA clean; parses under 5.1 and pwsh 7 |

### The safety property, and it is the point of the whole layer

`Invoke-SwdDialogButton` **refuses to click unless the dialog's own text matches a caller-supplied**
**`-ExpectLike` pattern.** A driver that blind-clicks OK on whatever dialog is up will eventually
accept "Delete this hydroscan?" - on a licensed install holding 143 reports, not recoverable.
`Matched` / `Clicked` / `Sent` are three separate fields so refused can never read as clicked.

**Mutation-checked:** neutering the gate (`$matched = $true`) is killed by 2 tests. Not decorative.

### Three bugs the new tests caught before any of this touched SWD

1. **`Get-SwdDialogControl` never populated `Text`.** `ConvertFrom-SwdControlRecord` parses only the
   structural record; `Get-SwdControl` adds text separately. So the safety gate matched a property
   that did not exist - it would have refused EVERYTHING. Fail-safe, but for the wrong reason, and
   it would have looked like the layer simply did not work.
2. `.Handle` on an empty array - StrictMode error, not empty.
3. `.Count` on a `Where-Object` matching nothing - `$null.Count` is an error, not zero.

### And one I caused

Python's `write_text` translates `
` -> `
` on Windows, so my earlier edits silently converted
`swd_msg.ps1` from LF to CRLF, leaving it **mixed** (1160 CRLF + 171 LF). The round-3 fixer had
reverted this exact conversion once already. Normalised back to pure LF; edits now pass
`newline=''` explicitly. **Check line endings after any scripted edit.**

---

## Verification scan spec - agreed 2026-08-28, pending SQA clearance

**Target board: `2003_Taylor_Knox_channel_island`**

| Criterion | Why this board |
|---|---|
| Unscanned | Nothing can be overwritten - it has no `.fynrhydro` |
| Distinct geometry | 2.277 kg / 31.92 L, matches no scanned board (unlike `default_shortboard_Copy_2`) |
| Turn radius **22.8 m** | A NEW radius. The corpus has 19.1, 30.1, 34.7, 45.9, 56.5, 87.3, 115.9, 312.1, 100000 - so this widens the radius axis as a side effect |
| Not a negative-radius board | `Jules_egg`, `blueTreck`, `hydroactive_Wake` are the ONLY three negatives in the library. They are worth a full 11-angle scan later, not a 3-angle smoke test |

**Parameters**

| Setting | Value | Note |
|---|---|---|
| Speed | **36 km/h = 10.000 m/s** | `ConvertTo-Kmh 10` -> 36. The boxes are km/h; typing `10` would ask for 2.78 m/s |
| Drift min / max / step | **0 / 20 / 10** -> angles 0, 10, 20 | Three angles, and all inside the drift <= 20 deg surfing envelope. Beyond that the board is broadside and drag reaches 522 kN |
| Expected duration | **~8 min** | 3 angles at the measured ~163 s each, vs ~31 min for eleven |

**The measurement that makes this worth doing.** The extractor recovers speed independently from the
planing mass balance `mdot = rho * A * V`. If 36 km/h was set and the recovered `scan_speed_ms` reads
**10.000 and not 20.039**, then in one run: the parameter path works, the scan honoured it, the
extractor's speed recovery is validated against a second value for the first time, and the corpus
finally has **two physical speeds**. That last one is the entire point of Phase 2.

**Note on physical realism:** 10 m/s is if anything MORE surf-realistic than the 20 m/s every
existing scan used - real surfing speeds are roughly 3-10 m/s. The risk to watch is the opposite one:
if the board fails to plane at the lower speed the mass-balance recovery may degrade. That would
itself be a finding, and it is why this is a 3-angle test rather than a 13-board batch.

**Before pressing anything:** `cp SWD/data/boards.csv` first - worklist item 8. Copy_1's unexplained
geometry difference exists precisely because no pre-scan snapshot survives.

---

## WP1 complete - paper supplementary data saved, 2026-08-31

[`CLAUDE.md`](../CLAUDE.md) section 9 item 1 closed. Three archives in `SWD/data/paper-supplementary/`, kept zipped,
with SHA-256 and a measured [`SOURCE.md`](data/paper-supplementary/SOURCE.md). No SWD, no SQA, no `.ps1` touched.

| Archive | Bytes | Inner file | Rows | Rate |
|---|---:|---|---:|---|
| `mmc1.zip` | 19,937 | `Board_Sample.txt` | 148 data | 14.62 Hz, non-uniform |
| `mmc2.zip` | 578,996 | `EMG_Sample.txt` | 20,001 | exactly 2000 Hz |
| `mmc3.zip` | 3,778,356 | `IMU_Sample.txt` | 20,001 | exactly 2000 Hz |

**Licence settled: CC BY 4.0**, read verbatim from the article's own page-1 footer. The plan's
"if unconfirmable, gitignore them" fallback does not apply - they are committable with attribution.
ScienceDirect returns HTTP 403 to automated requests, so the repo PDF was the source, not the landing
page.

### Four measured corrections to the description WP1 was planned against

Every figure came from reading inside the archives, not from filenames or the prior write-up.

1. **`Board_Sample.txt` is 296 lines, not 148 rows.** Strictly alternating: data row, then a
   `;`-prefixed echo line. The echo's hex field decodes to the exact text of the line above it in
   **148 of 148** cases - a transmission diagnostic with no independent content. Verified, not
   assumed. A plain `read_csv` ingests both halves.
2. **The three files are NOT on a common clock, and this is the consequential one.** `mmc2` and
   `mmc3` share an exact 225-235 s axis. `mmc1` is a board-side counter in **milliseconds** on its
   own epoch (~2262-2272 s), running **backwards**, sampled non-uniformly at 67-89 ms. The
   "all three start at t = 225 s" claim in the stage plan is **wrong**. Piloting Ratio `PR = SJ/BJ`
   needs board and surfer jerk co-registered, so it rests on an alignment step that is our
   assumption rather than the authors' measurement.
3. **One EMG channel is dead.** `L.Semitend.` holds the single value 3299.89917 across all 20,001
   rows, while the other seven channels each have ~19,900 distinct values and ~0.001 uV minima. A
   railed or disconnected electrode, not a resting muscle. **Seven usable channels, not eight**, so
   Muscle Activity `Sigma` and `D_MA,J` are half-instrumented on the semitendinosus term.
4. **`IMU_Sample.txt` has no header.** 92 fields = 1 time + **91** data columns; identities are not
   recoverable from the file. The paper text or the authors' scripts are needed to map them.

Also measured: **the French-locale trap does not apply.** Zero commas in any of the three files;
decimals are periods throughout. `mmc1` uses `;` as a field separator only.

### Findings 1 and 3 appear in no prior document

Both were found by reading the archives rather than trusting the plan's table. Finding 3 is a real
limitation on a graded metric and belongs in WP2's limitations section, not a footnote.

### Verified

| Check | Result |
|---|---|
| Three archives, valid zips, one member each | pass |
| SHA-256 re-hashed and matched against [`SOURCE.md`](data/paper-supplementary/SOURCE.md) | 3/3 |
| Byte counts matched against [`SOURCE.md`](data/paper-supplementary/SOURCE.md) | 3/3 |
| [`SOURCE.md`](data/paper-supplementary/SOURCE.md) UTF-8 **no BOM** | pass (`23 20 f0 9f 93 98`) |
| SWD process launched | none |
| Writes outside `SWD/data/paper-supplementary/` | none |

### Still open

[`SOURCE.md`](data/paper-supplementary/SOURCE.md) section 1 records that the authors will supply their **Arduino, Matlab and Python analysis
scripts on request**. Not needed now, but that is the reference implementation of the paper's own
metrics - worth an email if a BJ or Ra cross-check ever disagrees with the published values.

**Next:** [`CLAUDE.md`](../CLAUDE.md) section 9 item 2 - WP3 Steps 0-3, the verification scan. Needs SWD open and
supervised.

---

## First driven verification scan - AUTOMATION PASSED, EXPERIMENT FAILED, 2026-08-31

WP3 Steps 0-3 executed end to end under tool control. Full findings in
[`tools/phase2/LIVE-RUN-FINDINGS.md`](tools/phase2/LIVE-RUN-FINDINGS.md); dialog captures in [`tools/phase2/SCAN-FLOW.md`](tools/phase2/SCAN-FLOW.md).

### The gate failed, and the plan said what that means

`flow ms` was set to **10** and read back **10** immediately before the scan started. All **53** new
operating points recovered **scan_speed_ms = 20.0391** - unchanged from the whole existing corpus.

[`WP3-STEP-0-3-verification-scan.md`](docs/plans/WP3-STEP-0-3-verification-scan.md) section 7 wrote the consequence in advance: *"If it still reads
~20, the parameter path silently did nothing and Steps 4-7 do not start."* **Step 4 is blocked.**

The `flow ms` box belongs to the `Test Position` single-point solver (`Compute` / `Solve Planing`).
The hydroscan takes its speed from somewhere else, not yet located.

### Two more premises refuted

1. **The km/h premise is wrong.** There is no `NumericUpDownScanSpeed{1,2,3}kmh` control anywhere.
   The live box is `flow ms` - metres per second - inside `Surfing situation:`, with siblings
   `Slope` and `Surfer Kg`. Confirmed independently: the `Surfer Kg` box reads 80 and the window
   title reports `Surfer Pro(80Kg)`. Following the plan's `36` would have asked for 36 m/s.
   `ConvertTo-Kmh` must never be used on this control.
2. **The copy branch resets board physics.** A protected original cannot be scanned; SWD saves and
   loads a copy. The copy came back with `turn_radius_m` **22.806 -> 100000** and
   `board_speed_setting_ms` **10 -> 20**. This board was chosen precisely because 22.8 m was a radius
   the corpus lacked, so the run gained **neither a new speed nor a new radius**.

### What did work - the automation chain, first time against the real app

`Set-SwdNumeric`, `Invoke-SwdButton` and the whole dialog layer had never executed against SWD.

| | |
|---|---|
| `Set-SwdNumeric` | Before=5 After=10 Ok=True Reason=ok LastError=0, siblings unchanged |
| Scan start | `-Post` -> `Wait-SwdDialog -TitleLike` -> `-ExpectLike` matched -> `Wait-SwdDialogGone`=True |
| Scan | 11 angles, 18:16 -> 18:28, no human clicks after start |
| Extraction | 154/154 parsed, 0 failures, 1890/1890 polar blocks, 667 -> 720 points, 27 -> 28 boards |

**The safety gate refused a click on its first real outing** and was right to: a defect fed it
main-window text, and it returned `Matched=False, Attempted=False, REFUSED without clicking`.
Nothing was clicked, no scan started.

### Defects found, for the Step 4 SQA pass

1. **[Critical] `Process.MainWindowHandle` is unstable** - three different values in one session for
   one process. `Get-SwdDialog` excludes the main window by comparing against it, so the real main
   window leaks in as a dialog and unfiltered `Wait-SwdDialog` returns **instantly** instead of
   waiting. `MainWindowTitle` also returned `Starting HydroScan` at one point - which breaks Step 4's
   board-identity rule, since that rule reads the window title.
2. **[High] Always pass `-TitleLike` to `Wait-SwdDialog`** until 1 is fixed.
3. **[High] OneDrive locked the `.fynbs` mid-scan**, and SWD raised a pump-blocking modal:
   `erreur Serializer_surfboard_bin: ... being used by another process`. Transient, but an
   unattended batch writing a board file per board into a synced tree will hit it repeatedly.
4. **[Medium] Four dialogs exist, not one**, with two button vocabularies (`&Yes`/`&No` and
   `OK`/`Cancel`). Fixtures covered only the third.
5. **[Medium] `Test-SwdOwnsForeground` without its two mandatory parameters hangs silently** - an
   invisible interactive prompt in a background elevated shell, unkillable from a Medium shell.
6. **[Info] No drift min/max/step controls exist.** The plan's 0/20/10 -> 3 angles is not achievable
   from this UI; the scan runs SWD's default 11-angle set. Stopping early is the only limiter, and
   each angle is saved as computed so partial results survive.

### Cost model - the "2.7x faster" re-base is WITHDRAWN, same evening

~61 s per angle was measured against ~163 s on 2026-08-28 and read as a speed effect. **It is not.**
That scan ran at **20.0391 m/s**, so both figures are ~20 m/s measurements and the difference is
board geometry, not speed. Individual angles ran 51-128 s.

**The only real low-speed datum contradicts it.** With a wave loaded (average wave speed 6.59 m/s),
**not one of 11 angles completed in 11 minutes** while SWD computed continuously. At 6.59 m/s a
2.1 kg board under an 80 kg surfer is at or below planing threshold. **No validated cost model
exists for a low-speed batch, and it may be far more expensive than 20 m/s, not less.**

### Unfocused click - evidence, not proof

`Apply situation` was clicked with `Test-SwdOwnsForeground` returning **False before and after**:
`Sent=True Observed=handled LastError=0`. First real-application evidence for the headless premise.
**Not proof the control acted** - no observable state changed, and `Apply situation` may be a no-op
when values are current. Close worklist item 1 only with a control whose caption changes.

### Next - SUPERSEDED, same day

This block used to read *"find the control that actually sets hydroscan speed, by reading it, before
scanning again"*. **That search is finished and the answer is that no such control exists.** The
enumeration was completed later on 2026-08-31 - `Solver option:` holds three buttons and no numeric
field at all, and `flow ms` drives the single-point solver rather than the hydroscan. Written up in
[`SWD/docs/what-swd-can-yield.md`](docs/what-swd-can-yield.md) § 2-3 and closed as item 2a in [`CLAUDE.md`](../CLAUDE.md) § 9.

The open candidate that replaced it is **item 2b, the surfer-mass axis** - one board scanned against
two surfer profiles, ~24 min, supervised. Untested; nothing asserts it works.

### Unresolved

A surfer mass of **50 kg** was reported on screen during the run. Every instrument read **80** - the
`Surfer Kg` box, the window title, and the configuration panel. No visible control matched 50. The
control has not been located, and surfer mass enters the planing solution.

---

## WP2 complete - the metrics reference, 2026-08-31

[`SWD/docs/performance-metrics.md`](docs/performance-metrics.md), written as an **internal working reference** and labelled as one at
the top: source material for the report, implementing nothing, and containing no AI-acknowledgement or
academic-integrity text. Every figure was read from the article PDF this session; nothing was carried
over from an earlier summary.

### The paper defines 17 equations, not two

The project has been treating Charles et al. as defining Board-Jerk and Radicality because those are
the two [`mma3001-project-spec.md`](../mma3001-project-spec.md) names. It defines a sensor layer (Eq 1-3), four primary indicators
(Eq 4-11), five discriminators (Eq 12-16), a mechanical-coupling ratio (Eq 17), and a five-phase wave
decomposition. All 17 are now transcribed with their symbols, units and windows.

### The self-consistency audit - 71 of 72

Equations 11-17 form a closed system: Table 8's per-phase jerks generate Tables 5, 6 and 7, and Tables
4-8 generate Table 9. Every such relationship was recomputed from the paper's own published values.

    Eq 11  Ra = theta_z * Rbar_z        2 checks   pass
    Eq 12  D_raw,I = I_Top/Ra           4 checks   pass
    Eq 13  I_N = I_Top/I_Bottom         4 checks   pass
    Eq 14  D_B,I = I_N/Ra               6 checks   pass
    Eq 15  D_MA,J = MA_N/J_N            4 checks   3 pass, 1 FAIL
    Eq 16  PR = SJ/BJ, all phases      12 checks   pass
    Eq 17  MI = M/I, every cell        40 checks   pass
                                       -----------------------
                                       72 checks   71 pass, 1 fail

**This is the point of the document.** Matching two headline numbers is weak evidence; an
implementation that reproduces Table 8 gets Tables 5, 6, 7 and 9 for free, and a failing row localises
the error to one equation.

### The one failure

Table 7's `D_MA,BJ` on wave 5 publishes **0.89**. Eq 15 gives `MA_N/BJ_N = 1.69/1.77 = 0.955`. Rounding
cannot bridge that: reaching 0.89 would need `MA_N = 1.575` against a published 1.69. Wave 4 is
inconclusive. Recorded as **does not reproduce**, with the arithmetic, and not resolved - `SJ_N/BJ_N`
reproduces both published values exactly, but what the authors intended is not something this project
can determine. `D_MA,SJ` reproduces cleanly on both waves, so Eq 15 itself is sound.

### Four findings that appear in no prior document

1. **Signal processing.** Surfer IMU: 4th-order Butterworth lowpass, **7 Hz**. EMG: 4th-order bandpass
   **20-400 Hz**, then RMS over a **300 ms** sliding window. Load-bearing, because jerk is a third
   derivative and each differentiation amplifies whatever the filter left behind. Two implementations
   differing only in cutoff will not produce comparable `J`.
2. **The paper names a different muscle than its own data ships.** Eq 9 sums `A_BF`, Biceps Femoris.
   `EMG_Sample.txt` ships `Semitend.` - semitendinosus. Both hamstrings, not the same muscle. Three of
   four channels map cleanly; the hamstring does not, **and it is the same channel that is dead**.
3. **Radicality's implied duration disagrees with the published phase duration.** `t1-t0 = theta_z/Rbar_z`
   gives 0.565 s on wave 4; the muscle-activity breakdown reports the top turn as 0.8 s. Most likely the
   MA phase window is broader than the `R_x = 0` maneuver window - stated as a plausible reading, not a
   resolved fact, because the choice changes the numbers.
4. **Wave 4's phase durations sum to 6.4 s against a wave described as 5 s.** Excluding paddling gives
   4.0 s. Neither matches. `T` enters `C = T^5/D^2` at the fifth power, so 4.0 against 5.0 is roughly a
   factor of three in `C`. Recorded without a proposed reconciliation.

### The `D` defect, characterised rather than restated

[`CLAUDE.md`](../CLAUDE.md) § 7 already says the two supplied specs disagree about `D` and to follow the paper. Reading
Eq 7 shows **why**: the equation computes the magnitude of net displacement, while the sentence
introducing it calls `D` *"the length of the overall trajectory"* - a different quantity. The maths is
unambiguous, the prose is not, and [`mma3001-project-spec.md`](../mma3001-project-spec.md)'s arc-length reading is a faithful
transcription of the sentence. [`surfing-performance-io.md`](../surfing-performance-io.md) transcribes the **equation** correctly, so
only one of the two spec files is wrong. Neither was edited; both are supplied material.

### A PDF trap worth not re-learning

Text extraction **drops the decimal comma in Table 9 only**: `-0,123` comes out as `-0123`, three orders
of magnitude wrong and entirely plausible-looking. All 40 cells were reconstructed as `M/I` from Tables
4-8 and verified. Reconstruct that table; never parse it.

### Not done, deliberately

No indicator is implemented, no code was written, and no report prose was drafted. The audit's
arithmetic is reproducible from the tables printed inside the document itself, so no script ships with
it - the ~60 lines exist and can become `SWD/tools/verify_paper_tables.py` if a runnable check is
wanted.
