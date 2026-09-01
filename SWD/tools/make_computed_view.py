"""Build the computed-data/ view for an extracted SWD board.

The board directory mixes values read out of SWD's binary reports with values
this project computed. MMA3001 grades "inputs and outputs" and "computational
solution" separately, so the split has to be visible on disk.

It is a VIEW, not a relocation. ``extract_board.ps1`` and ``census_board.ps1``
write into the board directory's root and would recreate anything moved out of
it, so everything they own is copied rather than moved. Only trajectory.csv,
whose producer this project controls, actually moves.

Nothing here recomputes a value. The derived tables are column selections, so
there is no second implementation of the density decomposition to drift against
the first.

Run
---
    python SWD/tools/make_computed_view.py [board_dir]
"""

from __future__ import annotations

import shutil
import sys
from pathlib import Path

import pandas as pd

VIEW = "computed-data"

# Keys are extracted; they are carried so each row joins back to its source.
# n_sub_elements counts an extracted structure rather than deriving a quantity,
# and incidence_deg_stored_parent is SWD's own value joined down from the parent
# element - both are labelled as such in the README rather than sold as physics.
DERIVED = {
    "elements.csv": (
        ["board", "drift_deg", "roll_case", "element_index"],
        ["rho_v_kg_m2_s", "rho_kgm3", "scan_speed_ms",
         "incidence_deg_derived", "incidence_deg_residual", "n_sub_elements"],
    ),
    "sub_elements.csv": (
        ["board", "drift_deg", "roll_case", "element_index", "sub_index"],
        ["rho_v_kg_m2_s", "rho_kgm3", "scan_speed_ms",
         "incidence_deg_derived", "incidence_deg_stored_parent"],
    ),
}

COPIES = ["operating_points.csv", "field_census.csv"]


def build(board_dir: Path) -> Path:
    view = board_dir / VIEW
    view.mkdir(parents=True, exist_ok=True)

    # Move, idempotently: already-moved is success, not a missing source.
    src, dst = board_dir / "trajectory.csv", view / "trajectory.csv"
    if src.exists():
        shutil.move(str(src), str(dst))
        print(f"  moved   trajectory.csv")
    elif dst.exists():
        print(f"  moved   trajectory.csv (already in place)")
    else:
        print("  WARNING trajectory.csv not found - run SWD/model/trajectory.py")

    for name in COPIES:
        s = board_dir / name
        if not s.exists():
            print(f"  WARNING {name} not found - skipped")
            continue
        shutil.copy2(s, view / name)
        print(f"  copied  {name:24} {len(pd.read_csv(s)):6,} rows")

    for name, (keys, cols) in DERIVED.items():
        s = board_dir / name
        if not s.exists():
            print(f"  WARNING {name} not found - skipped")
            continue
        df = pd.read_csv(s)
        missing = [c for c in keys + cols if c not in df.columns]
        if missing:
            raise SystemExit(f"{name}: expected columns absent: {missing}")
        out = view / name.replace(".csv", "_derived.csv")
        # utf-8, no BOM: a BOM breaks the readers downstream (project rule).
        df[keys + cols].to_csv(out, index=False, encoding="utf-8")
        print(f"  derived {out.name:24} {len(df):6,} rows x {len(keys)+len(cols)} cols")

    (view / "README.md").write_text(readme(), encoding="utf-8")
    print(f"  wrote   README.md")
    return view


def readme() -> str:
    return """# Computed data — `default_shortboard`

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
"""


if __name__ == "__main__":
    board_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else \
        Path(__file__).resolve().parents[1] / "data" / "default_shortboard"
    if not board_dir.is_dir():
        raise SystemExit(f"not a directory: {board_dir}")
    print(f"building {board_dir / VIEW}")
    v = build(board_dir)
    print(f"\n{len(list(v.iterdir()))} files in {v}")
