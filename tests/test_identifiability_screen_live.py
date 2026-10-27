"""Known-answer tests for the second identifiability screen (``src/swd_model/identifiability_screen_live.py``).

Each has an answer that does not depend on the physics being right: an arithmetic filter, an
interpolant through its own data, a drag law with a closed-form speed history, and recovery of
the planted multiplier from noise-free data.
"""

from __future__ import annotations

import numpy as np
import pandas as pd
import pytest

from src.swd_model import identifiability_screen as ids
from src.swd_model import identifiability_screen_live as live


@pytest.fixture(scope="module")
def chosen():
    """The forces and V0 the screen's own rules pick."""
    df, _ = live.load_forces()
    sel = live.select(df, 10.055)
    return df, sel["forces"], sel["v0"]


def test_filter_keeps_rows_whose_components_sum_to_the_total():
    """100 = 10 + 80 + 10 is kept; 100 vs 10 + 80 + 12 (2 % off) is dropped."""
    df = pd.DataFrame({"drag_total_n": [100.0, 100.0], "friction_n": [10.0, 10.0],
                       "fx_planing_n": [80.0, 80.0], "fx_rail_n": [10.0, 12.0]})
    kept, dropped = live.drop_inconsistent(df)
    assert dropped == 1
    assert kept.index.tolist() == [0]


def test_pchip_reproduces_the_grid_values_at_the_grid_speeds(chosen):
    """An interpolant passes through its own data; the last knot is evaluated through its cubic."""
    df, forces, _ = chosen
    lo, hi = forces.v_range
    g = df[(df.pos_y == forces.pos_y) & (df.pos_x == forces.pos_x) & df.speed_ms.between(lo, hi)].sort_values("speed_ms")
    v = g.speed_ms.to_numpy(dtype=float)
    for interp, col in ((forces.friction, "friction_n"), (forces.planing, "fx_planing_n"), (forces.rail, "fx_rail_n")):
        np.testing.assert_allclose(interp(v), g[col].to_numpy(), rtol=1e-12, atol=0)


@pytest.mark.parametrize("n", [2.0, 13 / 7], ids=["n=2", "n=13/7"])
def test_power_law_drag_matches_the_closed_form(n):
    """m dV/dt = -c V^n (zero slope) has V(t) = [V0^(1-n) + (n-1) c t / m]^(1/(1-n))."""
    c, m, v0, t_end = 3.0, 81.8, 8.3, 10.055
    sol = live.integrate(lambda v: c * v**n, v0, t_end, (0.01, 100.0), m=m, slope_deg=0.0)
    t = np.linspace(0.0, t_end, 101)
    exact = (v0 ** (1 - n) + (n - 1) * c * t / m) ** (1 / (1 - n))
    assert sol.t[-1] == t_end
    assert np.max(np.abs(sol.sol(t)[0] / exact - 1)) < 1e-8


@pytest.mark.parametrize("joint", [False, True], ids=["set a: k", "set b: k and V0"])
def test_noise_free_fit_recovers_planted_k(chosen, joint):
    """With no noise the least-squares minimum is the planted value, from a shifted start."""
    _, forces, v0 = chosen
    t = ids.sample_times(ids.load_mmc1(), 3.0)
    data, t_reached, _ = live.run_accel(forces, live.PLANTED, v0, 3.0, t)
    assert t_reached == 3.0 and data.size == t.size
    f = live.fit(forces, data, 0.0283, t, 3.0, v0, joint)
    assert f["converged"]
    assert abs(f["k_fit"] - live.PLANTED) / live.PLANTED < 1e-6
