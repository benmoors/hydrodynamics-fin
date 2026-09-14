# `default_shortboard` extraction — progress

Scope: one board, treated as representative. Find every value that can be extracted
from it and deliver ML-ready CSVs. Plan: `~/.claude/plans/could-you-do-some-purring-lamport.md`

| # | Task | Status |
|---|---|---|
| 1 | Census script (`SWD/tools/census_board.ps1`), read-only, PS 5.1 | ✅ done |
| 2 | Run census — 340 fields across 3 types | ✅ done — `field_census.csv` |
| 3 | Probe nested containers (`probe_nested.ps1`, `probe_aggregate.ps1`) | ✅ done |
| 4 | Verify library files unmodified (SHA-256 before/after) | ✅ done — 12 files, 0 differences |
| 5 | Extractor (`SWD/tools/extract_board.ps1`) → 5 CSVs | ✅ done |
| 6 | Regression: new `elements.csv` == existing 22 cols on 467 rows | ✅ done — max\|diff\| = 0 on all 14 |
| 7 | `alpha` derived vs `list_incidences_deg` stored | ✅ done — they differ; see finding 8 |
| 8 | [`DATA-DICTIONARY.md`](DATA-DICTIONARY.md), generated from the data | ✅ done — 18.9 KB, 54+ columns |
| 9 | Trajectory: equilibrium + `Vt(t)` at 100 Hz → `trajectory.csv` | ✅ done — `SWD/model/trajectory.py` |
| 10 | Bounded decompile: water density literal, friction correlation | ✅ done — both recovered, see findings 10–11 |
| 11 | **SQA loop on the `.ps1` files that need it** | ✅ **done** — see verdict progression below |
| 12 | Gitignore `geometry_contact.csv`; correct stale docs | ✅ done 2026-09-01 — 8 documents |
| 13 | Re-approve library + regenerate full corpus | ✅ done 2026-09-01 — user-authorised |
| 14 | Ledger + Efficiency Learning Brief | ✅ `qa-history/swd-board-extraction.md`, `briefs/swd-board-extraction-2026-09-01.md` |
| 15 | Split computed data from extracted into `computed-data/` | ✅ done 2026-09-01 — `SWD/tools/make_computed_view.py`, 6 files |

### SQA loop outcome

Goal class `functionality` (+ `security`). **No honest metric existed** — mutation scoring
needs `cosmic_ray`, which is Python-only — so this was a critic-only loop and no number was
invented. Closed at the 3-round cap.

| Pass | Verdict |
|---|---|
| `sqa-lead` round 1 | `Critical=1 \| Warning=9 \| Suggestion=24` |
| fixer round 1 | `(CLEAN)` |
| fixer round 2 | `Critical=0 \| Warning=1 \| Suggestion=1` |
| **fresh verifier** | `Critical=1 \| Warning=14 \| Suggestion=20` |
| fixer round 3 | **`(CLEAN)`** — 67/67 Pester, all named mutants killed |

**Corpus after regeneration:** 720/720 operating points at 20.000 m/s (was 566, with 154 at
the phantom 20.039); `Single.MaxValue` rows 68 → 0; `rho_kgm3` emitted (1023×566 / 1025×154);
`boards.csv` 28 → 29 rows; manifest carries a `rho` provenance block with
`snap_misses: 0, snap_worst_rel: 5.27e-06`. Pre-fix corpus backed up to
`~/.claude/qa-backups/20260831-193130-swd-data-pre-rho-fix/`.

**Outstanding, reported not fixed:** TOCTOU between hashing and deserialising (all three
scripts); shared sentinel filename between the two tools; `census_board.ps1` stale-manifest
deletion and uncounted `.fynbs` failures; 20 Suggestions. All recorded in the ledger § 6.

### Item 11 scope, when it runs

In scope: `census_board.ps1` and `extract_board.ps1` — both load the SWD assembly
and deserialise library files, so they are the ones the project rule is about.

Out of scope: `probe_nested.ps1` and `probe_aggregate.ps1` are throwaway diagnostics
that print and write nothing. Delete them or keep them as evidence, but they do not
warrant a QA round.

Interim assurance already done, and it is **not** a substitute for the loop:
PSScriptAnalyzer at Error severity (clean on both), an explicit write-path audit
(two writes, both inside `-OutDir`; every file open is `FileAccess::Read`), and a
SHA-256 before/after proving the 12 library files are byte-identical.

## Findings so far

**Confirmed independently** — 36 of 101 `element_hydrodynamique` fields are
`[NonSerialized]`; 151 of 231 on `Class_surfboard`. Both match the long-standing
figures in [`CLAUDE.md`](../../../CLAUDE.md).

**Census result** (467 elements, 51 roll cases, 11 reports, 0 failures):

| Type | Fields | populated | reference | constant_zero | constant | null | nonserialized |
|---|---:|---:|---:|---:|---:|---:|---:|
| `element_hydrodynamique` | 101 | 24 | 22 | 17 | 1 | 1 | 36 |
| `Class_surfboard` | 231 | 0 | 21 | 19 | 33 | 7 | 151 |
| `Class_rapport_hydrodynamique` | 8 | 1 | 6 | 0 | 0 | 0 | 1 |

### 1. `elements_internes` — 10× more data than is currently extracted
Every element holds exactly **10 sub-elements**: **4,670 total, 0 null, 4,621 with
non-zero `_Fz_planing_n`**, each with its own wetted length. The current extractor
ignores these entirely. This is the single biggest gain available on this board.

### 2. `list_incidences_deg` is real — α is stored, not just derivable
Per-element planing incidence in degrees, one list per roll case, counts matching
element counts exactly (9, 9, 9, 11, 9 for drift 10°). Sample: 45, 14.04, 10.22,
5.84, 4.87, 4.44. Lets the derived `α = asin(S/(L·w))` be **checked** rather than trusted.

### 3. `element_width_mm` carries `Single.MaxValue` — a live data defect
**68 of 6,867 rows corpus-wide (0.99%), 4 of 467 on this board**, all with
`wetted_length_mm = 0` — SWD's sentinel for a non-contact element. Passes straight
through the existing extractor (its zero-column detector only drops all-zero
columns). A single 3.4e38 would destroy standardisation for that feature.

### 4. Savitsky is dead on the hydroscan path
`_Cv_Savitsky`, `_lamda_Savitsky`, `_Cl0_Savitsky`, `_Cl0_theorique` are all
`constant_zero`. The binary documents Savitsky (1964) strip-wise, but this path runs
the deflected-mass-flux momentum model — matching the empirical result that
`Fz = Qm·Vr·sin α·cos α` reproduces `_Fz_planing_n` to ~1.0 across α bins.

### 5. Geometry is extractable, in metres
`tableau_..._outline_element_echelle_1_en_metres...` — 402 points, constant.
`tableau_..._surface_contact_eau_echelle_1_en_metres` — **22–365 points, varying**:
the wetted contact patch. Plus rail geometry (`array_vector2_normal_ligne_fond_du_rail_vers_ligne_contact`,
0–43 pts) and vertical sections (74–90 pts). `PremierPoint_m` / `DernierPoint_m` /
`_point_application_global_normal` are `Vector3` — element extent and centre of pressure.

### 6. Hypothesis raised and refuted
`nom='global'` + `infos='Contains all hydrodynamics elements'` on element 0 suggested
an aggregate that would make `operating_points.csv` double-count. **All 467 elements
carry the same two strings** — constant metadata, not an aggregate marker. No
double-counting. Recorded because a plausible-but-wrong lead is worth not re-chasing.

### 7. Stored and derived incidence are NOT the same quantity
`incidence_deg_derived` = `asin(S/(L·w))` (inverting Eq 20) vs SWD's stored
`list_incidences_deg`: median difference **−0.58°**, std **3.71°**, only **36.6%**
agree within 0.5°. They correlate but measure different things — the derived one is
an area-equivalent angle, the stored one is evaluated somewhere specific on the
strip. **Eq 24 reproduces `Fz_planing_n` to ≈1.0 with either**, so the momentum law
holds regardless; but the two must not be used interchangeably as a feature.
Below 2° incidence Eq 24 is off by ~2×, in both variants — a real limitation.

### 8. Trajectory results (`trajectory.csv`, 300 rows @ 100 Hz)
Equilibrium speed 6.66 / 7.37 / 8.01 m/s for a 65 / 80 / 95 kg surfer. One 3 s
carve at 35° max roll: speed 6.27–7.37 m/s, turn radius down to 6.66 m, yaw rate to
1.015 rad/s. **Board-Jerk J = 33.51**, **Radicality Ra = 0.702 rad²/s**.
A bug was found and fixed here: `np.sign` returns 0 at an exact zero, so one
roll-rate crossing registered as two adjacent ones and collapsed the `t0..t1`
window to a single 0.01 s sample, giving Ra = 0.0096 instead of 0.702. The
self-check now asserts against that specific collapse.

### 10. Water density is a LOOKUP TABLE — and it resolves two standing puzzles
`Form_shaper.actualiser_fluide()` selects ρ from a 4-entry table indexed by
`temperature_eau` ∈ {0, 10, 20, 30} °C, with separate salt and fresh arrays:
salt **1028 / 1027 / 1025 / 1023**, fresh 999.87 / 999.73 / 998.23 / 995.67,
salt viscosity 0.00182 / 0.00138 / 0.00107 / 0.00084 Pa·s. ρ can only ever be one
of eight values — it is never computed.

**Consequence 1 — the 0.015% density residual does not exist.** `mass_flux /
frontal_section` is exactly ρ·V and takes exactly **two** corpus-wide values:
20460.0 (5,404 elements) and 20500.0 (1,404) = `1023×20.000` and `1025×20.000`.
The old 20463.09 ± 10.68 was the mean of a bimodal mixture, and its "std" was the
mixture spread. On this board alone it is **20460.000 ± 0.002**.

**Consequence 2 — the "second scan speed" is not a speed.** `20500/1023 = 20.0391`
exactly. One flow speed (20.000 m/s) at two water temperatures, with the 1025-density
scans divided by an assumed 1023. [`CLAUDE.md`](../../../CLAUDE.md) § 5 has been corrected.

The extractor now infers ρ per element by snapping ρ·V/V_setting to the nearest table
value, and emits `rho_kgm3`, `rho_v_kg_m2_s` and a corrected `scan_speed_ms`
(20.000000 ± 2e-6 on all 467 rows).

### 11. The friction law, recovered and validated
`Module_couche_limite.epaisseur_couche_limite()` — **not ITTC-57, not Schoenherr**:
transition pinned at `Re_crit = 5e5`; laminar `Cf = 1.328/√Re` (Blasius); turbulent
`Cf = 0.031/Re^(1/7)`; fully-rough `Cf = (1.89 + 1.62·log₁₀(L/Ra))^−2.5`
(Schlichting) when `Ra > 50 µm`. Reimplemented in Python it reproduces SWD's own
`_Fx_friction_n` to **1–3% median**. The turbulent branch gives `F ∝ V^1.857`, so
total drag does **not** scale as clean `V²` — which is why `trajectory.py` scales
friction and planing separately.

### 13. Water temperature is NOT stored per board — `V_REF` cannot be measured
Checked against the census: `Class_surfboard`'s 231 fields contain **no** `temperature_eau`,
fluid, salinity or density field. The only matches are `foam_density_kgm3` (construction
material) and `temp_rapport_*` (unrelated `[NonSerialized]` report references).
`temperature_eau` and `salt_water` live only in `MySettings` — **global application state at
scan time**, not per-board metadata.

Three consequences:
- The temperature each historic scan ran at is **unrecoverable from the files**. ρ can only
  ever be inferred from the measured ρ·V product, which is what the extractor now does.
- The independent verifier's suggested route to convert `V_REF = 20.000` from an inference
  into a measurement — "read `temperature_eau` off a stored `.fynbs`" — **is closed.**
  `V_REF` stays an inference, and the guard stays a plausibility bound rather than a proof.
- `_Vecteur_vitesse_flux_relatif_ms` (the Vector3 velocity) is `[NonSerialized]` too, so the
  velocity is not directly recoverable either. `_vitesse_flux_relatif_ms` is a constant 20.0
  on this board, and is the board's stored *setting*, not the scan condition.

Note the residual tension, unresolved and worth stating: `SurfHydrodynamics.exe.config`
defaults to `temperature_eau=20, salt_water=True`, i.e. ρ = 1025 — yet the data assigns the
5,461-row majority to ρ = 1023 (30 °C). The data is decisive at **49.8σ**, so the setting must
have differed when those scans ran. Which is another way of saying: ρ is per-scan history, and
nothing on disk records it.

### 12. Dead ends — do not re-investigate
`index_point_contact` = −1 on every element. `index_point_decrochage`,
`point_attack_on_outline`, `_volume_deplacement_litres` all `constant_zero`.
`pression_pascals_surface_profil_base` is a zero-length array.
`vecteur_mecanique_axe_*` and `equation_plan_rotation_*` hold only unit axis
definitions (identity frame), not forces or moments.
