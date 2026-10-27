"""Tests for the jerk cost J, Eq 4-7 (src/forward_model/board_jerk.py).

(a) The author's linear case, a = a0 + beta t: J and D against his J_linear and D_a. Every step is exact here
    (np.gradient on a line, Simpson on a cubic), so this checks the plumbing, not convergence.
(b) The author's sinusoid, a = A sin(omega t) with omega T = pi: J against his J_sinusoidal, the error at h/4 within the
    h/2 -> h/4 change, and the observed order p_obs on h, h/2, h/4. np.gradient is second order, so 2.
(c) The author's run, simulate() at its defaults, subsampled to FD steps 4h, 2h and h: p_obs is 2.
(d) Units: J is dimensionless, so it is the same with a in mm/s^2, or with t in ms and a in m/ms^2.
(e) The invalid inputs: each one raises ValueError with its own message.

Every case, grid and tolerance here is the author's, chosen from the exploration tables (AI-USE.md section 4,
2026-10-27).
"""

from __future__ import annotations

from functools import lru_cache

import numpy as np
import pytest

from src.forward_model import board_jerk as bj
from src.forward_model import forward_model as fm

T = 3.0  # s
H = 0.001  # s
EXACT_TOL = 1e-12  # absolute, on J and on D (m) for the linear case
P_OBS_TOL = 0.1
UNITS_TOL = 1e-12  # relative change in J

# (a) The author's J_linear and D_a with a0 = 1 m/s^2, beta = -0.5 m/s^3, T = 3 s, hard-coded:
#     D_a = |1*9/2 - 0.5*27/6| = 2.25 m, J = 0.25*729/(2*2.25^2) = 18
LIN_A0, LIN_BETA = 1.0, -0.5
D_LINEAR, J_LINEAR = 2.25, 18.0
# (b) The author's J_sinusoidal with D_a, A = 1 m/s^2, omega = pi/3 rad/s: (omega T)^4/4 = pi^4/4, hard-coded
SIN_A, SIN_OMEGA = 1.0, np.pi/3
J_SINUSOIDAL = 24.352272758500604


def grid(h):
    """t = 0, h, ..., T, s."""
    return np.linspace(0.0, T, round(T/h) + 1)


def linear(t):
    return LIN_A0 + LIN_BETA*t


def sinusoid(t):
    return SIN_A*np.sin(SIN_OMEGA*t)


@lru_cache(maxsize=None)
def authors_run():
    """simulate() at its defaults, the only motion input."""
    return fm.simulate()


def p_obs(J_h, J_h2, J_h4):
    """The author's E18 on J: log2(|J_h - J_h/2| / |J_h/2 - J_h/4|).

    E18 is credited to Oberkampf; that reference is unconfirmed, with no title, page or equation number (TODO.md S.8).
    """
    return np.log2(abs(J_h - J_h2)/abs(J_h2 - J_h4))


# (a) The linear case
def test_linear_case() -> None:
    t = grid(H)
    J, D = bj.jerk_cost(t, linear(t), True), bj.displacement(t, linear(t))
    assert abs(D - D_LINEAR) <= EXACT_TOL, f"D = {D!r}"
    assert abs(J - J_LINEAR) <= EXACT_TOL, f"J = {J!r}"


# (b) The sinusoid
@lru_cache(maxsize=None)
def sinusoid_J():
    """J on the sinusoid at h, h/2 and h/4."""
    return [bj.jerk_cost(t, sinusoid(t), True) for t in (grid(H/2**k) for k in range(3))]


def test_sinusoid_within_step_halving() -> None:
    """The error at h/4 against J_sinusoidal is within the change from h/2 to h/4."""
    _, J_h2, J_h4 = sinusoid_J()
    error, change = abs(J_h4 - J_SINUSOIDAL), abs(J_h2 - J_h4)
    assert error <= change, f"error at h/4 {error:.3e} exceeds the h/2 to h/4 change {change:.3e}"


def test_sinusoid_observed_order() -> None:
    p = p_obs(*sinusoid_J())
    assert abs(p - 2) <= P_OBS_TOL, f"p_obs = {p:.4f}"


# (c) The author's run
def test_authors_run_observed_order() -> None:
    """J at FD steps 4h, 2h and h, every 4th, 2nd and 1st node of the one run; simulate() itself is not re-run."""
    t, _, a, complete = authors_run()
    assert complete
    J_4h, J_2h, J_h = (bj.jerk_cost(t[::s], a[::s], complete) for s in (4, 2, 1))
    assert np.isfinite(J_h) and J_h > 0
    p = p_obs(J_4h, J_2h, J_h)
    assert abs(p - 2) <= P_OBS_TOL, f"p_obs = {p:.4f}"


# (d) Units
@pytest.mark.parametrize("case", ["linear", "sinusoid", "author's run"])
def test_J_is_dimensionless(case) -> None:
    """a in mm/s^2 (x 1e3), and t in ms (x 1e3) with a in m/ms^2 (x 1e-6), leave J unchanged."""
    if case == "author's run":
        t, _, a, _ = authors_run()
    else:
        t = grid(H)
        a = linear(t) if case == "linear" else sinusoid(t)
    J = bj.jerk_cost(t, a, True)
    for t_scaled, a_scaled in ((t, a*1e3), (t*1e3, a*1e-6)):
        assert bj.jerk_cost(t_scaled, a_scaled, True) == pytest.approx(J, rel=UNITS_TOL, abs=0)


# (e) Invalid inputs: the author's six cases, then his two additions (an odd interval count, a t that doubles back),
#     then review round 1's (agy): a t or a that is not 1-D, and a bool a
T5 = np.linspace(0.0, T, 5)
A5 = linear(T5)


@pytest.mark.parametrize("t, a, complete, match", [
    ([3.0, 2.0, 1.0], [1.0, 1.0, 1.0], True, r"T = t\[-1\] - t\[0\] must be > 0"),
    ([0.0, 0.0, 0.0], [1.0, 1.0, 1.0], True, r"T = t\[-1\] - t\[0\] must be > 0"),
    (T5, np.zeros(5), True, "D = 0"),
    ([0.0, 1.0, np.nan], [1.0, 1.0, 1.0], True, "t and a must be finite"),
    (T5, [1.0, np.inf, 1.0, 1.0, 1.0], True, "t and a must be finite"),
    (T5, A5[:4], True, "t and a must be 1-D arrays of the same length"),
    (np.zeros((5, 1)), np.zeros((5, 1)), True, "t and a must be 1-D arrays of the same length"),
    (3.0, 1.0, True, "t and a must be 1-D arrays of the same length"),
    (T5, [True, False, True, False, True], True, r"t and a must be arrays of numbers \(a bool is not\)"),
    ([0.0, 3.0], [1.0, 1.0], True, "need at least 3 samples"),
    (T5, A5, False, "complete must be True"),
    (T5, A5, "True", "complete must be True"),
    (T5[:4], A5[:4], True, "even number of intervals"),
    ([0.0, 2.0, 1.0, 2.5, 3.0], A5, True, "t must be strictly increasing"),
])
def test_jerk_cost_rejects_invalid_inputs(t, a, complete, match) -> None:
    with pytest.raises(ValueError, match=match):
        bj.jerk_cost(t, a, complete)


def test_displacement_rejects_invalid_inputs() -> None:
    """displacement has the same sample checks; one of them stands for all."""
    with pytest.raises(ValueError, match="t and a must be finite"):
        bj.displacement(T5, [1.0, np.nan, 1.0, 1.0, 1.0])
