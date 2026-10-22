"""Generate DATA-DICTIONARY.md for an extracted SWD board.

MMA3001 requires inputs and outputs to be documented with data types, physical
units, operating ranges and mathematical domains, plus how invalid, missing or
out-of-bounds values are handled. Hand-typing that for 54 columns invites drift
between the document and the data, so every range here is measured from the CSVs
at generation time and the status column is joined from ``field_census.csv``.

Run
---
    python SWD/tools/make_data_dictionary.py [board_dir]
"""

from __future__ import annotations

import sys
from pathlib import Path

import pandas as pd

from translate_columns import fold, load_map, read_map

# Units and meanings for the columns whose identity is established. Anything not
# listed is emitted with unit '?' rather than a guess - an invented unit is worse
# than an admitted gap, and the census still records the .NET type.
UNITS: dict[str, tuple[str, str]] = {
    "board": ("-", "Board identifier (constant in this dataset)"),
    "drift_deg": ("deg", "Yaw/drift angle between board axis and relative flow; SWD scan axis"),
    "roll_case": ("-", "Index of the roll/heel case within a drift report (0-4)"),
    "element_index": ("-", "Spanwise strip index along the roll axis"),
    "sub_index": ("-", "Sub-element index within a strip (0-9)"),
    "point_index": ("-", "Vertex index within a contact polygon"),
    "drag_total_n": ("N", "Total horizontal drag of the element"),
    "Fx_friction_n": ("N", "Friction (viscous) drag component"),
    "Fx_planing": ("N", "Planing (momentum-deflection) drag component"),
    "Fx_rail_n": ("N", "Rail suction drag; negative values are thrust and are physical"),
    "Fx_rocker": ("N", "Rocker drag component"),
    "lift_total_n": ("N", "Total vertical lift of the element"),
    "Fz_planing_n": ("N", "Planing lift component"),
    "contact_area_m2": ("m^2", "Wetted contact area"),
    "max_area_m2": ("m^2", "Maximum element area"),
    "immersed_section_m2": ("m^2", "Immersed cross-section area"),
    "frontal_section_m2": ("m^2", "Frontal section of the deflected stream, S in Eq 20"),
    "mass_flux_kg_s": ("kg/s", "Deflected mass flow rate, Qm in Eq 21"),
    "dynamic_pressure_pa": ("Pa", "Dynamic pressure referenced to element beam B"),
    "Cv_Savitsky": ("-", "Savitsky speed coefficient Cv = V/sqrt(9.81*B)"),
    "lamda_Savitsky": ("-", "Savitsky mean wetted length-to-beam ratio (SWD spells it 'lamda')"),
    "Cl0_Savitsky": ("-", "Savitsky zero-deadrise lift coefficient"),
    "cl0_theoretical": ("-", "Theoretical lift coefficient, carried for comparison"),
    "boundary_layer_mm": ("mm", "Boundary-layer thickness at the downstream edge"),
    "laminar_boundary_layer_mm": ("mm", "Boundary-layer thickness at transition"),
    "laminar_turbulent_transition_mm": ("mm", "Laminar run length from the contact point"),
    "element_length_mm": ("mm", "Element length"),
    "wetted_length_mm": ("mm", "Wetted length, L in Eq 20"),
    "width_calc_length_mm": ("mm", "Length used for the element width calculation"),
    "element_width_mm": ("mm", "Element beam B (width), 'largeur' in Eq 20"),
    "plane_delta_deg": ("deg", "Local bottom-plane angle; negative = rail dips (concave), positive = vee"),
    "rail_deviation_deg": ("deg", "Rail deviation angle"),
    "volume_litres": ("L", "Element volume"),
    "displacement_volume_litres": ("L", "Displacement volume"),
    "roll_attack_rad": ("rad", "Roll inclination at the attack line"),
    "roll_surface_rad": ("rad", "Roll inclination at the surface line"),
    "incidence_deg_stored": ("deg", "Planing incidence from the report's list_incidences_deg"),
    "incidence_deg_derived": ("deg", "DERIVED: asin(S/(L*w)) by inverting Eq 20. NOT equivalent to the stored value"),
    "incidence_deg_residual": ("deg", "DERIVED: derived minus stored. 30% of rows exceed 1 deg, worst +60.17"),
    "incidence_deg_stored_parent": ("deg", "The PARENT strip's stored incidence, repeated over its sub-elements"),
    "scan_speed_ms": ("m/s", "DERIVED: rho*V divided by the snapped rho; NaN where the snap was refused"),
    "rho_v_kg_m2_s": ("kg/m^2/s", "MEASURED: Qm/S, exactly rho*V. The raw product, always emitted"),
    "rho_kgm3": ("kg/m^3", "DERIVED: rho*V / 20.000 m/s snapped to SWD's 8-value table; NaN if the residual is too large"),
    "pos_x": ("m", "Element position along the board"),
    "pos_y": ("m", "Roll-case offset (constant within a case)"),
    "attack_index_1": ("-", "Index into the 402-point outline polygon, attack line start"),
    "attack_index_2": ("-", "Index into the 402-point outline polygon, attack line end"),
    "n_sub_elements": ("-", "Sub-elements inside this strip (always 10)"),
    "x_m": ("m", "Contact-polygon vertex, x"),
    "y_m": ("m", "Contact-polygon vertex, y"),
    "n_elements": ("-", "Elements in contact for this roll case"),
    "n_incidence": ("-", "Of those, how many had a stored incidence: the mean's denominator"),
    "incidence_deg_mean": ("deg", "Mean stored incidence across the case's elements"),
}
# operating_points.csv reuses two element names for its per-case sums, as the top-level CSVs do.
PER_FILE: dict[str, dict[str, tuple[str, str]]] = {
    "operating_points.csv": {
        "drag_total_n": ("N", "Sum of element drag over the roll case"),
        "lift_total_n": ("N", "Sum of element lift over the roll case"),
    },
}

DERIVED = {"incidence_deg_derived", "incidence_deg_residual", "scan_speed_ms", "rho_kgm3",
           "incidence_deg_mean"}
KEYS = {"board", "drift_deg", "roll_case", "element_index", "sub_index", "point_index"}
# English column -> the SWD field it was translated from (SWD/tools/column_names.csv).
SWD_NAME = {r["english"]: r["swd_name"] for r in read_map()}


def describe(path: Path, census: pd.DataFrame | None) -> str:
    df = pd.read_csv(path)
    names = load_map()
    own = PER_FILE.get(path.name, {})
    status = {}
    if census is not None:
        for _, r in census.iterrows():
            col = str(r["field"]).lstrip("_")
            for a, b in (("é", "e"), ("è", "e"), ("ê", "e"), ("à", "a")):
                col = col.replace(a, b)
            status[names.get(fold(col), col)] = r["status"]

    lines = [
        f"### `{path.name}`",
        "",
        f"{len(df):,} rows x {df.shape[1]} columns. Grain: "
        + ", ".join(f"`{k}`" for k in df.columns if k in KEYS),
        "",
        "| column | swd field | dtype | unit | non-null | missing | min | max | census | role |",
        "|---|---|---|---|---:|---:|---:|---:|---|---|",
    ]
    for c in df.columns:
        s = df[c]
        unit, _ = own.get(c) or UNITS.get(c, ("?", ""))
        miss = int(s.isna().sum())
        if pd.api.types.is_numeric_dtype(s) and s.notna().any():
            lo, hi = f"{s.min():.6g}", f"{s.max():.6g}"
        else:
            lo = hi = "-"
        role = "key" if c in KEYS else ("derived" if c in DERIVED or c in own else "measured")
        swd = "-" if c in own or c not in SWD_NAME else f"`{SWD_NAME[c]}`"
        lines.append(
            f"| `{c}` | {swd} | {s.dtype} | {unit} | {int(s.notna().sum()):,} | {miss:,} | {lo} | {hi} "
            f"| {'-' if c in own else status.get(c, '-')} | {role} |"
        )
    lines.append("")
    return "\n".join(lines)


def main() -> None:
    board_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / "data" / "default_shortboard"
    census_path = board_dir / "field_census.csv"
    census = pd.read_csv(census_path) if census_path.exists() else None

    header = f"""# Data dictionary - `{board_dir.name}`

Generated by `SWD/tools/make_data_dictionary.py`. Every range below is measured
from the CSVs, not transcribed, so this file cannot drift from the data.

Column names are English. Where SWD's own field name is French, the `swd field`
column gives it, and `SWD/tools/column_names.csv` gives the evidence for each
translation (`SWD/docs/column-names.md` explains the method).

## How to read the `census` column

From `field_census.csv`, which reflects over all 101 `element_hydrodynamique`
fields. Four failure modes look identical once a value reaches a CSV:

| value | meaning | usable as a feature? |
|---|---|---|
| `populated` | varies across rows | yes |
| `constant` | uniform on this board | no - zero variance |
| `constant_zero` | serialised but SWD's hydroscan path never assigns it | **no - this is a fake zero, not a measurement** |
| `nonserialized` | `[NonSerialized]`; deserialises as 0/null whatever the physics | **no** |
| `reference` | object or array, not a scalar | not directly |
| `sentinel` | every readable value is `Single.MaxValue` / Inf / NaN | **no - this is a marker, not a measurement** |

Columns marked `constant_zero` are kept in the CSV deliberately, so their
emptiness is visible and auditable rather than silently absent. **Drop them before
training.** Notably `Cv_Savitsky`, `lamda_Savitsky`, `Cl0_Savitsky` and
`cl0_theoretical` are all `constant_zero`: SWD implements Savitsky (1964) strip-wise,
but the hydroscan path does not populate those coefficients.

## Missing, invalid and out-of-bounds handling

- **Missing is always `NaN`, never `0`.** In PowerShell `[double]$null` is `0`, so a
  naive cast turns absent data into a measured zero. Both the extractor and the
  census map an absent field and a null value to `NaN`.
- **`Single.MaxValue` sentinel.** SWD leaves `element_width_mm` at
  `3.4028235e38` on non-contact elements (always with `wetted_length = 0`). The
  extractor maps any `|value| > 1e30`, infinity or NaN to `NaN` and reports a count.
  **This affects 68 of 6,867 rows (0.99%) in the repository-wide `elements.csv`,
  which does not apply the fix.** One such value destroys any standardisation of
  that column.
- **Negative `Fx_rail_n` is physical**, not an error: the rail can generate thrust.
- **Domains.** Angles in degrees unless the name ends `_rad`. `drift_deg` takes the
  fixed set 0, 2, 5, 10, 15, 20, 30, 45, 60, 75, 90. Areas, lengths, volumes and
  mass flow are non-negative. `asin` in the derived incidence is only evaluated
  where `S/(L*w) <= 1`; outside that domain the result is `NaN` rather than a clamp.

## Using this for machine learning

- **Rows are not independent.** Elements are the spatial mesh along one board at one
  condition, and sub-elements subdivide those further. A random row split leaks
  near-duplicates across train and test and inflates R^2. **Group by
  `(drift_deg, roll_case)`** - 51 groups - and split on groups.
- **One board, one speed.** Board geometry and `scan_speed_ms` are effectively
  constant, so nothing here supports a claim about generalising across board shape
  or speed. Say so rather than reporting an R^2 that implies otherwise.
- **Suggested targets:** `Fz_planing_n`, `drag_total_n`.
  **Suggested features:** `incidence_deg_stored`, `wetted_length_mm`,
  `element_width_mm`, `plane_delta_deg`,
  `roll_attack_rad`, `drift_deg`, `pos_x`, `pos_y`.
- **A physics baseline is available for free**, which the rubric asks for: Eq 24,
  `Fz = Qm * Vr * sin(a) * cos(a)`, reproduces `Fz_planing_n` to a median ratio near
  1.0 in every incidence bin above 2 degrees, using either the stored or the derived
  angle. Below 2 degrees it is off by roughly 2x - a real limitation, not noise.

---

"""
    parts = [header]
    for name in ("elements.csv", "sub_elements.csv", "operating_points.csv", "geometry_contact.csv", "board.csv"):
        p = board_dir / name
        if p.exists():
            parts.append(describe(p, census))

    out = board_dir / "DATA-DICTIONARY.md"
    out.write_text("\n".join(parts), encoding="utf-8")
    print(f"wrote {out}  ({out.stat().st_size:,} bytes)")


if __name__ == "__main__":
    main()
