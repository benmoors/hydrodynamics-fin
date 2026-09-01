# Computed data — `default_shortboard`

Everything in this folder was **computed by this project**. Nothing here was read
out of a SWD report file. The parent directory holds the extracted data.

| File | What it is |
|---|---|
| `trajectory.csv` | 100% model output. SWD has no time axis; this is a prescribed 3 s carve integrated at 100 Hz |
| `operating_points.csv` | Per-(drift, roll) aggregates of the extracted element rows |
| `field_census.csv` | Statistics over the extracted fields, plus the status label this project assigned each one |
| `elements_derived.csv` | The computed columns of `elements.csv`, with their keys |
| `sub_elements_derived.csv` | The computed columns of `sub_elements.csv`, with their keys |

## Three things to know

**This is a view, not the only home.** `extract_board.ps1` and `census_board.ps1`
write into the parent directory and would recreate anything moved out of it, so
`operating_points.csv` and `field_census.csv` are copies. `trajectory.csv` is the
one genuine move — this project owns its producer. Regenerate the whole folder
with `python SWD/tools/make_computed_view.py`.

**The computed columns also remain inside `elements.csv` and `sub_elements.csv`.**
The extractor writes each table atomically, and splitting the columns out at
source would mean editing a script that carries a CLEAN SQA verdict and 67 passing
tests. The tables here are selections of those same columns — no value is
recomputed, so there is nothing to drift.

**Two columns are not derivations, and are labelled rather than quietly counted:**

- `n_sub_elements` counts an extracted structure. It is a count, not physics.
- `incidence_deg_stored_parent` is SWD's own stored incidence, joined down from the
  parent element. The value is extracted; only its placement here is ours.

## What the computed values rest on

`rho_kgm3`, `rho_v_kg_m2_s` and `scan_speed_ms` come from snapping the measured
`mass_flux / frontal_section` product to the 4-entry density table recovered from
`Form_shaper.actualiser_fluide()`, divided by an assumed `V_REF = 20.000 m/s`.
**`V_REF` is an inference, not a stored value** — water temperature lives in global
application settings and is never written to a board file. It fails safe (an
unexpected speed yields NaN and a warning), but it is load-bearing under every
density and every recovered speed in this folder.

`incidence_deg_derived` inverts `S = L·sin α·w`. It is **not** the same quantity as
the extracted `incidence_deg_stored`: median difference −0.58°, σ 3.71°, only 36.6%
agree within 0.5°. Do not use them interchangeably as a feature.

`trajectory.csv` takes SWD's force response and drives it through a manoeuvre this
project prescribed. SWD supplies the physics; the manoeuvre is an assumption.
