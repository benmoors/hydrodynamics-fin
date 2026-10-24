"""Known-answer tests for the identifiability screen (``SWD/model/identifiability_screen.py``).

Each case has an exact answer that does not depend on the physics being right: the shape of
the published archive, bit-for-bit agreement with ``trajectory.simulate``, zero difference
between identical runs, exact interpolation of a straight line, and recovery of the planted
multiplier from noise-free data.
"""

from __future__ import annotations

import numpy as np
import pandas as pd
import pytest

from SWD.model import identifiability_screen as ids
import trajectory as tr  # put on sys.path by the import above


@pytest.fixture(scope="module")
def polar():
    """SWD's default_shortboard polar at zero drift."""
    return tr.load_polar()


@pytest.fixture(scope="module")
def mmc1():
    """The paper's board sample, parsed."""
    return ids.load_mmc1()


def test_mmc1_parser_returns_148_ascending_rows_over_10_055_s(mmc1):
    """SOURCE.md: 148 data rows once the echo lines go, a 10.055 s span, time reversed."""
    t = mmc1.t_s.to_numpy()
    assert len(mmc1) == 148
    assert t[0] == 0.0
    assert np.all(np.diff(t) > 0)
    assert t[-1] == pytest.approx(10.055, abs=1e-9)


def test_k1_with_default_v0_reproduces_trajectory_simulate_exactly(polar):
    """k = 1 multiplies friction by exactly 1.0, so the mirrored loop must match bit for bit."""
    ref = tr.simulate(polar, slope_deg=ids.SLOPE_DEG)
    got = ids.simulate(polar, k=1.0)
    for col in got.columns:
        assert np.array_equal(got[col].to_numpy(), ref[col].to_numpy()), col


def test_two_identical_runs_give_zero_difference(polar, mmc1):
    """Same k, same V0, same grid: the difference is exactly zero, not merely small."""
    t = ids.sample_times(mmc1, 3.0)
    runs = [ids.at_samples(ids.simulate(polar, k=ids.PLANTED, t_cover=t[-1]), t) for _ in range(2)]
    assert np.array_equal(runs[0] - runs[1], np.zeros_like(runs[0]))


def test_interpolation_reproduces_a_linear_signal(mmc1):
    """Linear interpolation of a straight line is the line, at uneven times too."""
    grid = np.arange(0.0, 3.02, 0.01)
    df = pd.DataFrame({"timestamp": grid, "accel_x_ms2": 2.0 + 3.0 * grid,
                       "accel_y_ms2": -1.5 * grid, "accel_z_ms2": 0.25 - 0.5 * grid})
    t = ids.sample_times(mmc1, 3.0)
    expected = np.column_stack([2.0 + 3.0 * t, -1.5 * t, 0.25 - 0.5 * t])
    np.testing.assert_allclose(ids.at_samples(df, t), expected, rtol=1e-12, atol=1e-12)


@pytest.mark.parametrize("joint", [False, True], ids=["set a: k", "set b: k and V0"])
def test_noise_free_fit_recovers_planted_k(polar, mmc1, joint):
    """With no noise the least-squares minimum is the planted value, from a shifted start."""
    t = ids.sample_times(mmc1, 3.0)
    v0 = tr.equilibrium_speed(polar, ids.MASS_KG)
    data = ids.at_samples(ids.simulate(polar, k=ids.PLANTED, v0=v0, dt=0.01, t_cover=t[-1]), t)
    sigma = np.full(3, ids.RESOLUTION_SIGMA)
    k_fit, _, converged = ids.fit(polar, data, sigma, t, 3.0, 0.01, v0, joint)
    assert converged
    assert abs(k_fit - ids.PLANTED) / ids.PLANTED < 1e-6
