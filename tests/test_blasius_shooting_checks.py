"""Regression tests for RK4 and Blasius shooting checks."""

from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np

BLASIUS_DIR = Path(__file__).resolve().parents[1] / "friction-function" / "blasius-shooting"
if str(BLASIUS_DIR) not in sys.path:
    sys.path.insert(0, str(BLASIUS_DIR))

import shooting_blasius as sb  # noqa: E402


def test_rk4_fourth_order_on_harmonic_oscillator() -> None:
    """rk4_solve achieves E(h)/E(h/2) -> 16 and Oberkampf p_obs -> 4 on y'' + 4y = 0."""
    t_end = 10.0
    y0 = [1.0, 0.0]

    def sho_rhs(_t: float, y: np.ndarray) -> np.ndarray:
        return np.array([y[1], -4.0 * y[0]])

    counts = 100 * 2 ** np.arange(6)
    runs = []
    for n in counts:
        t = np.linspace(0.0, t_end, int(n) + 1)
        y = sb.rk4_solve(sho_rhs, y0, t, t_end / float(n))[:, 0]
        runs.append((t, y))

    errors = np.array([np.max(np.abs(y - np.cos(2.0 * t))) for t, y in runs])
    ratio = errors[:-1] / errors[1:]
    p_exact = np.log2(ratio)
    diffs = np.array([np.max(np.abs(y_h - y_h2[::2])) for (_, y_h), (_, y_h2) in zip(runs, runs[1:])])
    p_obs = np.log2(diffs[:-1] / diffs[1:])

    assert np.allclose(ratio, 16.0, rtol=0.05)
    assert np.allclose(p_exact, 4.0, atol=0.1)
    assert np.allclose(p_obs, 4.0, atol=0.1)


def test_blasius_profile_matches_white_table_to_five_decimals() -> None:
    """Shot Blasius profile agrees with White & Majdalani Table 4-3 within 5-decimal rounding."""
    s_star, _, _, _ = sb.secant_for_shooting(sb.F, sb.GUESS_ddf, sb.GUESS2_ddf)
    blasius = sb.rk4_solve(sb.blasius_rhs, [sb.INITIAL_f, sb.INITIAL_df, s_star], sb.ETA_ARRAY, sb.STEP_SIZE)

    idx = np.rint(sb.white_eta / sb.STEP_SIZE).astype(int)
    on_grid = np.isclose(sb.ETA_ARRAY[idx], sb.white_eta)
    assert int(on_grid.sum()) == 33

    table = np.array([sb.exact_blasius(eta)[:3] for eta in sb.ETA_ARRAY[idx[on_grid]]])
    blasius_error = np.max(np.abs(blasius[idx[on_grid]] - table), axis=0)
    half_ulp_bound = 0.5e-5 * np.array([np.sqrt(2.0), 1.0, 1.0 / np.sqrt(2.0)])
    # Table rounding plus 1e-6 for the RK4's own error (rounding alone fails at h = 0.2/sqrt(2))
    assert (blasius_error <= half_ulp_bound + 1e-6).all()


def test_f_double_prime_zero_settles_under_eta_max_and_step_halving() -> None:
    """f''(0) settles within TOLERANCE under eta_max=20 and step halving with p_obs near 4."""
    cases = [
        (sb.ETA_MAX, sb.STEP_SIZE),
        (2.0 * sb.ETA_MAX, sb.STEP_SIZE),
        (2.0 * sb.ETA_MAX, sb.STEP_SIZE / 2.0),
        (2.0 * sb.ETA_MAX, sb.STEP_SIZE / 4.0),
    ]
    shots = []
    for eta_max, h in cases:
        eta = np.arange(sb.ETA_0, eta_max, h)
        s_val, _, _, _ = sb.secant_for_shooting(
            lambda s, eta=eta, h=h: sb.F(s, eta, h),
            sb.GUESS_ddf,
            sb.GUESS2_ddf,
            precision=1e-12,
        )
        shots.append(s_val)

    shots_arr = np.array(shots)
    assert (np.abs(np.diff(shots_arr)) < sb.TOLERANCE).all()
    assert (np.abs(shots_arr - sb.white_ddf[0]) <= 0.5e-5 / np.sqrt(2.0)).all()

    s_h, s_h2, s_h4 = shots_arr[1:]
    p_obs = np.log2(abs(s_h - s_h2) / abs(s_h2 - s_h4))
    assert np.isclose(p_obs, 4.0, atol=0.1)


def test_notebook_enforces_table_and_settle_assertions() -> None:
    """rk4_blasius_checks_cc.ipynb asserts the 5-decimal table bound and f''(0) p_obs check."""
    nb_path = BLASIUS_DIR / "rk4_blasius_checks_cc.ipynb"
    nb = json.loads(nb_path.read_text(encoding="utf-8"))
    cells_by_id = {cell.get("id"): "".join(cell.get("source", [])) for cell in nb["cells"]}

    assert "assert" in cells_by_id["c06"], "Section 2 cell c06 must assert the 5-decimal table bound"
    assert "p_obs" in cells_by_id["c12"] and "np.isclose(p_obs" in cells_by_id["c12"], (
        "Section 4 cell c12 must assert that p_obs for f''(0) is near 4"
    )
