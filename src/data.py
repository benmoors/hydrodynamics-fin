"""Assemble the surrogate's training table from the extracted SWD corpus.

Scope boundary
--------------
``SWD/`` is data acquisition and is **frozen and extract-only**: ``extract_board.ps1``
and ``census_board.ps1`` carry a CLEAN SQA verdict and 67 Pester tests, and nothing
this project computes is ever written back into ``SWD/data/``. So the training table
is built here, in memory, at load time. Every function in this module reads; none
writes.

What is a feature and what is not
---------------------------------
The surrogate exists to *replace the solver*. A feature must therefore be something
known **before** SWD runs -- board geometry and the operating condition. Several
columns in ``operating_points.csv`` are solver *outputs* and using them as inputs
would make the model score well and be useless:

``contact_area_m2``, ``volume_litres``, ``n_elements``
    The wetted contact patch, displaced volume and mesh size are results of the
    planing solution. At query time none of them is known.

``turn_radius_m``
    Per-board metadata, 9 distinct values across 14 boards and the straight-line
    sentinel ``100000.0`` on 309 of 720 rows. Regressing on it teaches board
    identity, which is exactly what a board-grouped split is designed to prevent.

``scan_speed_ms``, ``board_speed_setting_ms``
    Speed is not a feature. Every row was computed at 20.000 m/s;
    ``board_speed_setting_ms`` is the GUI box as last saved and is *not* the
    condition the solver ran at.

See :data:`FEATURES` and :data:`EXCLUDED` for the resulting lists.
"""

from __future__ import annotations

import warnings
from pathlib import Path

import numpy as np
import pandas as pd

from src.geometry import aspect_ratio, reconstruct_dimensions

__all__ = [
    "DATA_DIR",
    "EXCLUDED",
    "FEATURES",
    "TARGETS",
    "build_training_table",
    "load_boards",
    "load_operating_points",
]

#: Extracted corpus. Read-only from this module's point of view.
DATA_DIR = Path(__file__).resolve().parents[1] / "SWD" / "data"

#: Model inputs: board shape plus the operating condition, all knowable before a solve.
#:
#: Absolute ``length_m`` is deliberately NOT here. It is ``cbrt(V*lw/(k*tl))`` -- a
#: deterministic function of the three shape features -- so it carries no information
#: an RBF kernel could not already reach, while importing collinearity (r = 0.715 with
#: volume) and the calibration's 1.56 % uncertainty. It is still returned by
#: :func:`load_boards` for reporting and for the physics baseline, which genuinely
#: needs a Reynolds length.
FEATURES: list[str] = [
    "volume_shape_l",        # L     board volume,                       24.0 - 130.7
    "length_over_width",     # -     outline aspect ratio,               2.91 - 5.56
    "thickness_over_length", # -     relative thickness at wide point, 0.0105 - 0.0425
    "drift_deg",             # deg   operating condition,                   0 - 20
    "roll_rad",              # rad   operating condition,             -0.397 - 1.368
]

#: Model outputs, all newtons, all board totals for one (board, drift, roll_case).
TARGETS: list[str] = [
    "drag_total_n",
    "drag_friction_n",
    "drag_planing_n",
    "drag_rail_n",
    "lift_total_n",
]

#: Columns deliberately withheld, with the reason. Quoted in the report.
EXCLUDED: dict[str, str] = {
    "contact_area_m2": "solver output, unknown at query time",
    "volume_litres": "solver output (displaced volume), not board volume",
    "n_elements": "solver mesh size, an output",
    "turn_radius_m": "per-board metadata; regressing on it learns board identity",
    "scan_speed_ms": "constant 20.000 m/s across all 720 rows -- zero variance",
    "board_speed_setting_ms": "GUI setting, not the condition the solver ran at",
    "total_mass_kg": "r = 0.9915 with volume_shape_l; collinear duplicate",
    "foam_mass_kg": "r = 1.0000 with volume_shape_l; exact collinear duplicate",
    "volume_float_l": "a flag, not a measurement: 0.0 or exactly volume_shape_l",
    "yaw_rate_rad_s": "derived from turn_radius_m; inherits its board-identity leak",
}


def load_boards(data_dir: Path = DATA_DIR) -> pd.DataFrame:
    """Read every per-board ``board.csv`` and derive its shape descriptors.

    Parameters
    ----------
    data_dir : pathlib.Path, optional
        Root of the extracted corpus. Defaults to :data:`DATA_DIR`.

    Returns
    -------
    pandas.DataFrame
        One row per board with columns ``board``, ``volume_shape_l``,
        ``length_over_width``, ``thickness_over_length``, ``length_m``, ``width_m``,
        ``thickness_m``.

    Raises
    ------
    FileNotFoundError
        If no ``board.csv`` is found at all, which means the extractor has not been
        run and every downstream number would be silently empty.

    Notes
    -----
    Directories without a ``board.csv`` are skipped rather than faked. That is a
    live case: ``default_shortboard_Copy_1`` was refused by the provenance gate
    because its ``.fynbs`` content changed after the trust manifest was built.
    """
    rows = []
    for path in sorted(data_dir.glob("*/board.csv")):
        record = pd.read_csv(path).iloc[0]
        record["board"] = path.parent.name
        rows.append(record)
    if not rows:
        raise FileNotFoundError(
            f"no board.csv under {data_dir}. Run SWD/tools/extract_board.ps1 first."
        )

    boards = pd.DataFrame(rows).reset_index(drop=True)
    boards["length_over_width"] = aspect_ratio(
        boards["x_min"], boards["x_max"], boards["y_min"], boards["y_max"]
    )
    boards["thickness_over_length"] = boards["epaisseur_relative_au_wide_point"]
    boards = boards.rename(columns={"volume_shape_litres": "volume_shape_l"})

    length, width, thickness = reconstruct_dimensions(
        boards["volume_shape_l"],
        boards["length_over_width"],
        boards["thickness_over_length"],
    )
    boards["length_m"], boards["width_m"], boards["thickness_m"] = length, width, thickness

    return boards[[
        "board", "volume_shape_l", "length_over_width", "thickness_over_length",
        "length_m", "width_m", "thickness_m",
    ]]


def load_operating_points(data_dir: Path = DATA_DIR) -> pd.DataFrame:
    """Read the corpus-level ``operating_points.csv``.

    Parameters
    ----------
    data_dir : pathlib.Path, optional
        Root of the extracted corpus.

    Returns
    -------
    pandas.DataFrame
        720 rows x 22 columns as extracted; nothing is added or renamed here.

    Raises
    ------
    FileNotFoundError
        If the file is absent.
    """
    path = data_dir / "operating_points.csv"
    if not path.exists():
        raise FileNotFoundError(f"{path} not found. Run SWD/tools/swd_extract.ps1 first.")
    return pd.read_csv(path)


def build_training_table(
    data_dir: Path = DATA_DIR,
    max_drift_deg: float | None = 20.0,
) -> pd.DataFrame:
    """Join operating points to board geometry and apply the operating envelope.

    Parameters
    ----------
    data_dir : pathlib.Path, optional
        Root of the extracted corpus.
    max_drift_deg : float or None, optional
        Drop rows above this drift angle. Defaults to 20 deg. Beyond it the board is
        approaching broadside and drag reaches 522 kN -- roughly 53 tonnes of force,
        which is bluff-body drag rather than surfing, and it dominates every error
        metric computed over the full angle set. Pass ``None`` to keep all 11 angles.

    Returns
    -------
    pandas.DataFrame
        Columns ``board`` + :data:`FEATURES` + :data:`TARGETS`, one row per
        (board, drift, roll_case).

    Warns
    -----
    UserWarning
        If any board has operating points but no extracted geometry. Those rows are
        dropped -- they cannot be featurised -- and the warning names the boards so
        the loss is visible rather than silent.

    Notes
    -----
    The join is on the exact ``board`` key. A substring or ``str.contains`` join
    would conflate ``2003_Taylor_Knox_channel_island`` (unscanned) with
    ``2003_Taylor_Knox_channel_island_Copy_1`` (scanned) and double-count.
    """
    points = load_operating_points(data_dir)
    boards = load_boards(data_dir)

    missing = sorted(set(points["board"]) - set(boards["board"]))
    if missing:
        warnings.warn(
            f"{len(missing)} board(s) have operating points but no extracted geometry "
            f"and are dropped: {', '.join(missing)}",
            UserWarning,
            stacklevel=2,
        )

    table = points.merge(boards, on="board", how="inner", validate="many_to_one")

    if max_drift_deg is not None:
        table = table[table["drift_deg"] <= max_drift_deg]

    keep = ["board", *FEATURES, "length_m", "width_m", "thickness_m", *TARGETS]
    return table[keep].reset_index(drop=True)
