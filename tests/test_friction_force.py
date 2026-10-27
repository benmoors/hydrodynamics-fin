"""Tests for the friction drag F_f(V).

(a) With SWD's laminar law 1.328/sqrt(Re) and the same turbulent closure, F_f equals physics_baseline's
    friction_force to round-off for the same inputs.
(b) Fully laminar (x_tr capped at L): F_f = 1/2 rho V^2 A 4 f''(0)/sqrt(Re_L) with White's f''(0), to the error
    budget of test_skin_and_shear.
(c) F_f is continuous either side of the all-laminar speed V* = RE_CRIT nu/L.
(d) The Kármán laminar law runs; the PCHIP geometry returns the live-solver values; invalid inputs are refused.
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pandas as pd
import pytest

FRICTION_DIR = Path(__file__).resolve().parents[1] / "friction-function"
for folder in (FRICTION_DIR, FRICTION_DIR / "von-karman"):
    if str(folder) not in sys.path:
        sys.path.insert(0, str(folder))

import friction_force as ff  # noqa: E402
import von_karman as vk  # noqa: E402
from src.physics_baseline import friction_force as baseline_friction_force  # noqa: E402
from tests.test_skin_and_shear import WHITE, error_budget  # noqa: E402

RHO, MU = 1025.0, 0.00107  # SWD salt water, 20 degC: physics_baseline looks mu up from rho = 1025
NU = MU/RHO
AREA, LENGTH = 0.5, 0.1  # m^2, m: all laminar below V* = 5e5 nu/0.1 = 5.22 m/s


def constant(value):
    """A geometry callable that returns value at every speed."""
    return lambda V: np.full_like(np.asarray(V, dtype=float), value)


def test_matches_physics_baseline_with_swd_laminar_law() -> None:
    """Same inputs, SWD's 1.328/sqrt(Re): the two implementations agree to round-off, laminar and mixed."""
    V = np.array([0.5, 2.0, 5.0, 8.3, 10.0])
    for length in (LENGTH, 1.53026416):
        ours = ff.F_f(V, constant(AREA), constant(length), RHO, MU, laminar_avg_C_f=lambda Re: 1.328/np.sqrt(Re))
        np.testing.assert_allclose(ours, baseline_friction_force(length, AREA, V, rho_kgm3=1025), rtol=1e-13, atol=0)


def test_laminar_law_never_sees_re_above_re_crit() -> None:
    """V*x_tr/nu rounds one ulp above RE_CRIT at some speeds; the laminar law must get min(Re_L, RE_CRIT) instead."""
    seen = []

    def strict_law(Re):
        seen.append(np.max(Re))
        return 1.328/np.sqrt(Re)

    ff.F_f(np.linspace(1.0, 20.0, 10001), constant(AREA), constant(1.53026416), RHO, MU, laminar_avg_C_f=strict_law)
    assert max(seen) <= ff.RE_CRIT


@pytest.mark.xfail(strict=True, reason="physics_baseline.friction_force: rho*V*x_tr/mu rounds one ulp above RE_CRIT at "
                                       "this speed, so its laminar run takes the turbulent law (found 2026-10-27, "
                                       "not fixed: the author's decision)")
def test_physics_baseline_round_off_at_transition() -> None:
    """At 2.3 m/s, L = 1.53 m, physics_baseline is 12.7 % above F_f with the same laws (5.136 N against 4.558 N): its
    laminar run takes the larger turbulent coefficient. At the corpus speed of 20 m/s the rounding does not happen
    for any of SWD's salt-water densities, so no baseline result in the repository is affected."""
    V, length = 2.3, 1.53026416
    ours = ff.F_f(V, constant(AREA), constant(length), RHO, MU, laminar_avg_C_f=lambda Re: 1.328/np.sqrt(Re))
    np.testing.assert_allclose(ours, baseline_friction_force(length, AREA, V, rho_kgm3=1025), rtol=1e-13, atol=0)


def test_fully_laminar_is_blasius_drag_with_white_sigma() -> None:
    """x_tr = L below V*: F_f = 1/2 rho V^2 A 4 (sigma/sqrt 2)/sqrt(Re_L), sigma from Eq. 4-64."""
    V = np.array([0.5, 2.0, 5.0])
    white = 0.5*RHO*V**2*AREA*4*WHITE/np.sqrt(V*LENGTH/NU)
    rtol = sum(error_budget().values())/WHITE
    np.testing.assert_allclose(ff.F_f(V, constant(AREA), constant(LENGTH), RHO, MU), white, rtol=rtol, atol=0)


def test_continuous_at_all_laminar_speed() -> None:
    """Either side of V*, F_f moves by no more than its slope allows. On both sides |dF/dV| < 5 F/V (the laminar
    side goes as V^1.5; past V* the share term adds (C_turb - C_lam)/C_lam < 2 at Re = 5e5), so over V*(1 +/- eps)
    a continuous F_f changes by less than 10 eps F(V*); a jump between the two branches would be O(F)."""
    v_star = ff.RE_CRIT*NU/LENGTH
    eps = 1e-6
    below, at, above = ff.F_f(v_star*np.array([1 - eps, 1, 1 + eps]), constant(AREA), constant(LENGTH), RHO, MU)
    assert abs(above - below) < 10*eps*at, f"jump {above - below:.3e} N at V* = {v_star:.4f} m/s, F = {at:.4e} N"


def test_karman_laminar_law_runs() -> None:
    """With von_karman.avg_C_f passed in, F_f is the same split with the quartic's 4 BETA/sqrt(2 BETA/ALPHA)
    on the laminar run (the author's ALPHA = 379/2835, BETA = 5/3, hard-coded here)."""
    alpha, beta, length = 379/2835, 5/3, 1.53026416
    V = np.array([2.0, 5.0, 10.0])
    share = ff.RE_CRIT*NU/V/length
    by_hand = 0.5*RHO*V**2*AREA*(share*4*beta/np.sqrt(2*beta/alpha)/np.sqrt(ff.RE_CRIT)
                                 + (1 - share)*0.031/(V*length/NU)**(1/7))
    force = ff.F_f(V, constant(AREA), constant(length), RHO, MU, laminar_avg_C_f=vk.avg_C_f)
    np.testing.assert_allclose(force, by_hand, rtol=1e-13, atol=0)


def test_wetted_geometry_returns_solver_values() -> None:
    """At the converged speeds the PCHIPs return the CSV's area, and its length converted from mm to m."""
    data = pd.read_csv(ff.SOLVER_CSV)
    rows = data[(data.slope_deg == 0) & (data.drift_deg == 0) & (data.pos_y == ff.POS_Y)
                & (data.pos_x == ff.POS_X)].sort_values("speed_ms")
    A, L = ff.wetted_geometry()
    np.testing.assert_allclose(A(rows.speed_ms), rows.wetted_area_m2, rtol=1e-15)
    np.testing.assert_allclose(L(rows.speed_ms), rows.wetted_length_mm/1000, rtol=1e-15)


def test_wetted_geometry_rejects_unknown_attitude() -> None:
    with pytest.raises(ValueError, match="fewer than two converged speeds"):
        ff.wetted_geometry(pos_y=99.0)


def test_wetted_geometry_rejects_repeated_speed(tmp_path) -> None:
    """A PCHIP needs strictly increasing speeds; a duplicated row is refused with a clear message."""
    data = pd.read_csv(ff.SOLVER_CSV)
    rows = data[(data.slope_deg == 0) & (data.drift_deg == 0) & (data.pos_y == ff.POS_Y) & (data.pos_x == ff.POS_X)]
    path = tmp_path / "solver_points.csv"
    pd.concat([rows, rows.iloc[:1]]).to_csv(path, index=False)
    with pytest.raises(ValueError, match="repeated speeds"):
        ff.wetted_geometry(path)


@pytest.mark.parametrize("V, match", [
    (0.0, "V must be finite and positive"),
    (-2.0, "V must be finite and positive"),
    (np.nan, "V must be finite and positive"),
    ([], "V must be finite and positive"),
    (1.0, "outside the range"),  # below the converged 2-10 m/s
    (11.0, "outside the range"),
])
def test_rejects_invalid_speed(V, match) -> None:
    A, L = ff.wetted_geometry()
    with pytest.raises(ValueError, match=match):
        ff.F_f(V, A, L)


@pytest.mark.parametrize("rho, mu", [(0.0, MU), (RHO, -MU), (np.nan, MU), (np.array([RHO]), MU)])
def test_rejects_invalid_fluid(rho, mu) -> None:
    with pytest.raises(ValueError, match="rho and mu must be finite and positive scalars"):
        ff.F_f(2.0, constant(AREA), constant(LENGTH), rho, mu)


@pytest.mark.parametrize("area, length", [(-0.1, LENGTH), (AREA, 0.0)])
def test_rejects_invalid_geometry(area, length) -> None:
    with pytest.raises(ValueError, match=r"A\(V\) must be >= 0 and L\(V\) > 0"):
        ff.F_f(2.0, constant(area), constant(length), RHO, MU)
