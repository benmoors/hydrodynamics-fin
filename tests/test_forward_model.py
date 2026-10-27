"""Tests for the forward model of V(t), E15-E19 (src/forward_model/forward_model.py).

(a) E19, the author's closed form for m dV/dt = -c V^n with n = 2, against march: the error at h/4 is within the
    h/2 -> h/4 change, and the observed order p_obs on h, h/2, h/4 is 4 to within 0.1.
(b) Steady speed at a constant 10 deg: the run from 6 m/s approaches V*, the root of E15. V* is also checked against
    the speed where SWD's own drag_total_n crosses zero, a quantity the model never uses.
(c) The stop rule (A6): a run that leaves the force data stops there, with every returned node inside it.
(d) The author's run completes inside the data, and a is E15 at the node.
(e) The loader's checks, and the invalid inputs.

Every grid and tolerance here is the author's, chosen from the step-2 tables (AI-USE.md section 4, 2026-10-27).
"""

from __future__ import annotations

from functools import lru_cache

import numpy as np
import pandas as pd
import pytest
from scipy.optimize import brentq

from src.forward_model import forward_model as fm

# Hard-coded here, not imported, so a typo in the module cannot pass against itself
G = 9.81
MASS = 802.21/G  # kg

# (a) The author's E19 (AI-USE.md section 4, with the /m of section 5 E153): V = [V0^(1-n) - c(1-n)t/m]^(1/(1-n))
N_EXP = 2
V0_E19 = 2.0  # m/s
# N s^2/m^2: c = D(2 m/s, 20 deg, k = 1)/V0^n as of 2026-10-27, hard-coded and never computed from the force data
C_E19 = 79.66155266587084
T_E19 = 3.0  # s
E19_H = T_E19/96  # h, h/2, h/4 = 3/96, 3/192, 3/384 s
P_OBS_TOL = 0.1


def e19_exact(t):
    """The author's E19."""
    return (V0_E19**(1 - N_EXP) - C_E19*(1 - N_EXP)*t/MASS)**(1/(1 - N_EXP))


def e19_rhs(t, state):
    """m dV/dt = -c V^n, with no slope term and no force tables: it tests the integrator and the plumbing."""
    return np.array([-C_E19*state[0]**N_EXP/MASS])


@lru_cache(maxsize=None)
def e19_marches():
    """march on E19 at h, h/2 and h/4."""
    return [fm.march(e19_rhs, V0_E19, T_E19, E19_H/2**k) for k in range(3)]


def test_e19_within_step_halving() -> None:
    """The error at h/4 against E19 is within the change from h/2 to h/4 on their shared points."""
    (_, V_h2, _, _), (t_h4, V_h4, _, complete) = e19_marches()[1:]
    assert complete
    error = np.max(np.abs(V_h4 - e19_exact(t_h4)))
    change = np.max(np.abs(V_h2 - V_h4[::2]))
    assert error <= change, f"error at h/4 {error:.3e} exceeds the h/2 to h/4 change {change:.3e}"


def test_e19_observed_order() -> None:
    """p_obs = log2(|V_h - V_h/2| / |V_h/2 - V_h/4|) on the shared points, the author's E18: RK4 is 4.

    E18 is credited to Oberkampf; that reference is unconfirmed, with no title, page or equation number (TODO.md S.8).
    """
    (_, V_h, _, _), (_, V_h2, _, _), (_, V_h4, _, _) = e19_marches()
    p_obs = np.log2(np.max(np.abs(V_h - V_h2[::2]))/np.max(np.abs(V_h2 - V_h4[::2])))
    assert abs(p_obs - 4) <= P_OBS_TOL, f"p_obs = {p_obs:.3f}"


# (b) Steady speed at a constant 10 deg, the only constant slope at pos_x 0.45 with a stable steady speed in range
STEADY_SLOPE = 10.0  # deg
STEADY_V0, STEADY_T, STEADY_H, STEADY_TOL = 6.0, 30.0, 0.01, 0.05  # m/s, s, s, m/s; time constant about 7.6 s
# m/s: SWD's drag_total_n at 10 deg, pos_x 0.45, crosses zero between -3.535873 N at 7 m/s and 8.549601 N at 8 m/s;
# this is the linear zero, hard-coded
SWD_CROSSING = 7.292572140736888
EXTERNAL_TOL = 0.02  # m/s


@lru_cache(maxsize=None)
def v_star():
    """The stable root of E15 at the steady slope, between the unstable root near 4.3 m/s and 10 m/s."""
    D = fm.load_forces().D
    return brentq(lambda V: G*np.sin(np.radians(STEADY_SLOPE)) - D(V, STEADY_SLOPE, 1.0)/MASS, 6.0, 9.0, xtol=1e-12)


def test_steady_speed_is_approached() -> None:
    t, V, _, complete = fm.simulate(V0=STEADY_V0, theta_start=STEADY_SLOPE, theta_end=STEADY_SLOPE, T=STEADY_T,
                                    h=STEADY_H)
    assert complete and t[-1] == pytest.approx(STEADY_T)
    assert abs(V[-1] - v_star()) <= STEADY_TOL, f"V({STEADY_T} s) = {V[-1]:.4f}, V* = {v_star():.4f}"


def test_steady_speed_against_swd_drag_total() -> None:
    """V* from F_f + P + R + gravity against SWD's own drag_total_n, which the model never uses as a force."""
    assert abs(v_star() - SWD_CROSSING) <= EXTERNAL_TOL, f"V* {v_star():.4f} against SWD {SWD_CROSSING:.4f}"


# (c) The stop rule
def test_march_stops_before_a_trial_stage_leaves() -> None:
    """dV/dt = -1 from 1.5 with h = 0.1 and data only above 1.02: the stage from 1.1 to 1.0 leaves, so 1.1 is last."""
    def rhs(t, state):
        if state[0] < 1.02:
            raise fm.OutOfData("below 1.02")
        return np.array([-1.0])

    t, V, a, complete = fm.march(rhs, 1.5, 1.0, 0.1)
    assert not complete and len(t) == len(V) == len(a) == 5
    assert V[-1] == pytest.approx(1.1) and np.all(a == -1.0)


def test_run_stops_where_it_leaves_the_data() -> None:
    """On a flat face from 3 m/s the board slows below 2 m/s, the slowest speed in the data."""
    t, V, a, complete = fm.simulate(V0=3.0, theta_start=0.0, theta_end=0.0)
    assert not complete and t[-1] < fm.T_RUN
    assert len(t) == len(V) == len(a) and np.all((V >= 2.0) & (V <= 10.0))


# (d) The author's run
def test_authors_run_completes(authors_run) -> None:
    """20 -> 0 deg over 3 s from 6 m/s stays inside the data, and a at t = 0 is E15 written out here."""
    t, V, a, complete = authors_run
    assert complete and t[-1] == pytest.approx(3.0) and np.all((V >= 2.0) & (V <= 10.0))
    D = fm.load_forces().D
    assert a[0] == pytest.approx(G*np.sin(np.radians(20.0)) - D(6.0, 20.0, 1.0)/MASS, rel=1e-12)


# (e) The loader's checks
def authors_rows():
    """The drift-0 rows at the author's attitude."""
    data = pd.read_csv(fm.ff.SOLVER_CSV)
    return data[(data.drift_deg == 0) & (data.pos_y == 0.0) & (data.pos_x == 0.45)].reset_index(drop=True)


def at(rows, speed, slope):
    """The index of one (speed, slope) row."""
    return rows.index[(rows.speed_ms == speed) & (rows.slope_deg == slope)][0]


def doctor_0_deg(rows):
    rows.loc[at(rows, 6, 0), "drag_total_n"] *= 1.02
    return rows


def doctor_10_deg(rows):
    rows.loc[at(rows, 6, 10), "drag_total_n"] += fm.SLOPE_TOL + 5
    return rows


def doctor_missing(rows):
    return rows.drop(index=at(rows, 6, 10))


def doctor_wetted(rows):
    rows.loc[at(rows, 6, 10), "wetted_area_m2"] *= 1.1
    return rows


def doctor_duplicate(rows):
    return pd.concat([rows, rows.loc[[at(rows, 6, 10)]]], ignore_index=True)


@pytest.mark.parametrize("doctor, match", [
    (doctor_0_deg, "decomposition check failed"),
    (doctor_10_deg, "decomposition check failed"),
    (doctor_missing, "not complete"),
    (doctor_wetted, "wetted area or length changes with slope"),
    (doctor_duplicate, r"repeated \(speed, slope\) rows"),
])
def test_loader_refuses_doctored_rows(tmp_path, doctor, match) -> None:
    path = tmp_path/"solver_points.csv"
    doctor(authors_rows()).to_csv(path, index=False)
    with pytest.raises(ValueError, match=match):
        fm.load_forces(path)


@pytest.mark.parametrize("slope_tol, match", [
    (np.nan, "slope_tol must be a finite scalar"),
    (0.0, "slope_tol must be > 0"),
    (-5.0, "slope_tol must be > 0"),
])
def test_loader_rejects_invalid_slope_tol(slope_tol, match) -> None:
    with pytest.raises(ValueError, match=match):
        fm.load_forces(slope_tol=slope_tol)


def test_resistance_refuses_points_outside_the_data() -> None:
    D = fm.load_forces().D
    for V, slope in ((1.99, 10.0), (10.01, 10.0), (6.0, -10.01), (6.0, 20.01)):
        with pytest.raises(fm.OutOfData, match="is outside"):
            D(V, slope, 1.0)


@pytest.mark.parametrize("V, slope, k, match", [
    (np.nan, 10.0, 1.0, "V must be a finite scalar"),
    (7.0, np.nan, 1.0, "theta_deg must be a finite scalar"),
    (7.0, 10.0, np.nan, "k must be a finite scalar"),
    (7.0, 10.0, -1.0, "k must be >= 0"),
])
def test_resistance_rejects_invalid_inputs(V, slope, k, match) -> None:
    """A NaN is a ValueError, never an OutOfData stop."""
    with pytest.raises(ValueError, match=match):
        fm.load_forces().D(V, slope, k)


@pytest.mark.parametrize("t, T, match", [
    (0.0, 0.0, "T must be > 0"),
    (1.0, -3.0, "T must be > 0"),
    (-5.0, 3.0, r"t must be finite and in \[0, T\]"),
    (3.1, 3.0, r"t must be finite and in \[0, T\]"),
    (np.nan, 3.0, r"t must be finite and in \[0, T\]"),
    (True, 3.0, "t must be a number or a non-empty array of numbers"),
    ([], 3.0, "t must be a number or a non-empty array of numbers"),
])
def test_theta_rejects_invalid_inputs(t, T, match) -> None:
    with pytest.raises(ValueError, match=match):
        fm.theta(t, 20.0, 0.0, T)


# Invalid inputs
@pytest.mark.parametrize("kwargs, match", [
    ({"V0": np.nan}, "V0 must be a finite scalar"),
    ({"V0": np.inf}, "V0 must be a finite scalar"),
    ({"V0": [6.0]}, "V0 must be a finite scalar"),
    ({"V0": 0.0}, "V0 must be within the force data"),
    ({"V0": -1.0}, "V0 must be within the force data"),
    ({"V0": 1.9}, "V0 must be within the force data"),
    ({"k": -0.1}, "k must be >= 0"),
    ({"k": np.nan}, "k must be a finite scalar"),
    ({"k": True}, "k must be a finite scalar"),
    ({"V0": "6.0"}, "V0 must be a finite scalar"),
    ({"h": 0.0}, "T and h must be > 0"),
    ({"h": -0.001}, "T and h must be > 0"),
    ({"h": 0.0007}, "whole number of steps"),
    ({"T": 0.0}, "T and h must be > 0"),
    ({"theta_start": 25.0}, "theta_start must be within the force data"),
    ({"theta_start": -15.0}, "theta_start must be within the force data"),
    ({"theta_end": 21.0}, "theta_end must be within the force data"),
])
def test_simulate_rejects_invalid_inputs(kwargs, match) -> None:
    with pytest.raises(ValueError, match=match):
        fm.simulate(**kwargs)

# The author's decision of 2026-10-28 (AI-USE.md section 4): a regression value for V(3 s) at his tolerance
V_3S_AUTHORS_RUN = 6.090559208497497  # m/s, simulate() at its defaults, measured 2026-10-28 on main fd53694
REGRESSION_RTOL = 1e-6


def test_authors_run_V_regression(authors_run) -> None:
    _, V, _, complete = authors_run
    assert complete and V[-1] == pytest.approx(V_3S_AUTHORS_RUN, rel=REGRESSION_RTOL, abs=0)


def test_rk4_solve_first_k1_changes_nothing() -> None:
    """Handing rk4_solve the first slope (march does, 2026-10-28) gives the same step, bit for bit."""
    from src.friction.blasius_shooting.shooting_blasius import rk4_solve

    def rhs(t, y):
        return np.array([-0.3*y[0] + np.sin(t)])

    t = np.array([0.4, 0.45])
    assert np.array_equal(rk4_solve(rhs, [1.7], t, 0.05), rk4_solve(rhs, [1.7], t, 0.05, first_k1=rhs(0.4, [1.7])))
