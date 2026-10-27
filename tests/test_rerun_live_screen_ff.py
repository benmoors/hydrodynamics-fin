"""Tests for the Gate B rerun's two replacements, without running the screen's 60-min Monte Carlo.

load_forces_ff must keep the screen's own rows and change only friction_n at the held attitude, to F_f, with the
geometry read from the same CSV; select_held must hold the original run's attitude and V0.
"""

from __future__ import annotations


import numpy as np
import pandas as pd
import pytest

from src.friction import friction_force as ff
from src.friction import rerun_live_screen_ff as rerun
from src.swd_model import identifiability_screen_live as screen


def test_only_friction_at_the_held_attitude_changes() -> None:
    original, n_original = screen.load_forces()
    replaced, n_replaced = rerun.load_forces_ff()
    assert n_replaced == n_original and replaced.index.equals(original.index)
    at = (original.pos_y == rerun.POS_Y) & (original.pos_x == rerun.POS_X)
    assert at.sum() > 1
    pd.testing.assert_frame_equal(replaced.drop(columns="friction_n"), original.drop(columns="friction_n"))
    pd.testing.assert_series_equal(replaced.friction_n[~at], original.friction_n[~at])
    A, L = ff.wetted_geometry()
    np.testing.assert_allclose(replaced.friction_n[at], ff.F_f(original.speed_ms[at].to_numpy(float), A, L),
                               rtol=1e-15)


def test_rows_and_geometry_come_from_the_csv_passed(tmp_path) -> None:
    """In a CSV with the held attitude's 10 m/s row removed and its wetted area doubled, the kept rows lose that
    row and F_f doubles: neither the rows nor the geometry are read from the default CSV instead."""
    data = pd.read_csv(screen.SOLVER_CSV)
    at = (data.pos_y == rerun.POS_Y) & (data.pos_x == rerun.POS_X) & (data.slope_deg == 0) & (data.drift_deg == 0)
    data = data.drop(data.index[at & (data.speed_ms == 10)])
    data.loc[at, "wetted_area_m2"] *= 2
    path = tmp_path / "solver_points.csv"
    data.to_csv(path, index=False)
    changed, _ = rerun.load_forces_ff(path)
    default, _ = rerun.load_forces_ff()
    assert len(changed) == len(default) - 1
    held = (changed.pos_y == rerun.POS_Y) & (changed.pos_x == rerun.POS_X)
    np.testing.assert_allclose(changed.friction_n[held], 2*default.friction_n[held.index[held]], rtol=1e-14)


def test_select_holds_the_original_attitude_and_v0() -> None:
    summary = pd.read_csv(rerun.ORIGINAL_DIR / "summary.csv").set_index("metric")["value"]
    df, _ = rerun.load_forces_ff()
    held = rerun.select_held(df, 10.055)
    forces = held["forces"]
    assert (forces.pos_y, forces.pos_x) == (summary["attitude_pos_y"], summary["attitude_pos_x"])
    assert held["v0"] == pytest.approx(summary["v0_ms"]) and len(held["candidates"]) == 1
    A, L = ff.wetted_geometry()
    nodes = forces.friction.x
    np.testing.assert_allclose(forces.friction(nodes), ff.F_f(nodes, A, L), rtol=1e-14)
    assert forces.v_range == (summary["v_range_lo_ms"], summary["v_range_hi_ms"])


def test_select_holds_a_lower_ranked_attitude(monkeypatch) -> None:
    """The held attitude is also the top-ranked one, so hold the rank-2 attitude (0, 0.467) and check it is kept."""
    monkeypatch.setattr(rerun, "POS_X", 0.467)
    df, _ = rerun.load_forces_ff()
    held = rerun.select_held(df, 10.055)
    assert (held["forces"].pos_y, held["forces"].pos_x) == (0.0, 0.467)
    assert held["candidates"].pos_x.tolist() == [0.467]
