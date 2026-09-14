---
type: worklist
order: 1
item: "1"
status: done
effort: 30 min
blocked_by: nothing
plan: SWD/docs/plans/WP1-WP2-paper-data-and-metrics.md
---

# 1 — WP1: save the paper's supplementary data

| # | Item | Plan file | Effort | Blocked by | Status |
|---|---|---|---|---|---|
| 1 | ~~**WP1** — save the paper's supplementary data~~ | `WP1-WP2-paper-data-and-metrics.md` § 3 | 30 min | nothing | ✅ **2026-08-31** — see `SWD/data/paper-supplementary/SOURCE.md` |

**Links:** [plan](../plans/WP1-WP2-paper-data-and-metrics.md) · [SOURCE.md](../../data/paper-supplementary/SOURCE.md) · [worklist](worklist.base)

### ~~Why WP1 is first~~ — DONE 2026-08-31

The three archives are in `SWD/data/paper-supplementary/`, still zipped, with SHA-256 and a full
`SOURCE.md`. Licence confirmed **CC BY 4.0** from the article's own page-1 footer, so they are
committable with attribution.

**Four corrections that WP2 must not re-derive.** Everything below was measured by reading inside the
archives, and each contradicts the description WP1 was planned against:

- **`Board_Sample.txt` is 296 lines, not 148 rows.** It strictly alternates data row / `;`-prefixed
  echo line. The echo hex-decodes to the exact text of the line above it in **148 of 148** cases —
  a transmission diagnostic carrying no independent information. A naive `read_csv` ingests both.
- **The three files are NOT on a common clock.** `mmc2` and `mmc3` share an exact 225–235 s axis at
  2000 Hz. `mmc1` does not — it is a board-side counter in **milliseconds**, own epoch (≈2262–2272 s),
  running **backwards**, non-uniform at 67–89 ms (mean 14.62 Hz). The "all three start at t = 225 s"
  claim is **wrong**. Piloting Ratio `PR = SJ/BJ` therefore needs an alignment step that is our
  assumption, not the authors' measurement.
- **One EMG channel is dead.** `L.Semitend.` holds the single value 3299.89917 across all 20,001 rows
  while every other channel has ~19,900 distinct values. **Seven usable channels, not eight** — so
  Muscle Activity `Σ` and `D_MA,J` are half-instrumented on the semitendinosus term. Say so in WP2.
- **`IMU_Sample.txt` has no header** — 92 fields = 1 time + **91** data columns, identities not
  recoverable from the file. The paper text or the authors' scripts are required to map them.

The French-locale trap does **not** apply: zero commas in any of the three files, decimals are periods
throughout. `mmc1` uses `;` as a field separator only.
