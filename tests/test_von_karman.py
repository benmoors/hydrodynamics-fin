"""Tests for the Kármán momentum-integral layer of the Majdalani-Xuan quartic.

(a) delta, theta, C_f and avg C_f against the closed form, with the author's ALPHA and BETA hard-coded here.
(b) ALPHA and BETA from the profile itself: quad of g(1 - g), and wall_slope with a step-halving tolerance.
(c) The Table 4-1 Majdalani-Xuan row (White and Majdalani 2022, p.158), to half its last printed digit: the same
    profile, so a mismatch is an error, not a gap from Blasius.
(d) avg C_f = 2 theta(L)/L (Eq. 4-10), and the quartic's four boundary conditions.
(e) march_delta, RK4 on d(delta)/dx from x0 = 0.01 m, against the closed form: step halving and p_obs.
"""

from __future__ import annotations

from functools import lru_cache

import numpy as np
import pytest
from scipy.integrate import quad

from src.friction.blasius_shooting import skin_and_shear as ss
from src.friction.von_karman import von_karman as vk

# The author's derivation, hard-coded here, not imported, so a typo in the module cannot pass against itself
ALPHA = 379/2835
BETA = 5/3

# White and Majdalani (2022) Table 4-1, p.158, the Majdalani-Xuan row, printed to 3 decimals
TABLE_4_1 = {"delta sqrt(Re_x)/x": 4.993, "C_f sqrt(Re_x)": 0.668, "theta*": 0.134, "H": 2.618}
HALF_LAST_DIGIT = 0.5e-3

# Salt water at 20 degC, as SWD uses: rho = 1025 kg/m^3, mu = 0.00107 Pa s
NU = 0.00107/1025
U = 2.0
X = np.array([0.01, 0.05, 0.1, 0.2])
RE_X = np.array([1e3, 1e4, 1e5, 1e6])


# (a) The closed form
def test_delta_and_theta_against_closed_form() -> None:
    exact = np.sqrt(2*NU*BETA*X/(U*ALPHA))
    np.testing.assert_allclose(vk.delta(X, U, NU), exact, rtol=1e-14, atol=0)
    np.testing.assert_allclose(vk.theta(X, U, NU), ALPHA*exact, rtol=1e-14, atol=0)


def test_skin_friction_against_closed_form() -> None:
    np.testing.assert_allclose(vk.C_f(RE_X), 2*BETA/np.sqrt(2*BETA/ALPHA)/np.sqrt(RE_X), rtol=1e-14, atol=0)
    np.testing.assert_allclose(vk.avg_C_f(RE_X), 4*BETA/np.sqrt(2*BETA/ALPHA)/np.sqrt(RE_X), rtol=1e-14, atol=0)


# (b) ALPHA and BETA from the profile
def test_alpha_is_integral_of_profile() -> None:
    """ALPHA = theta/delta = integral of g(1 - g) from 0 to 1."""
    value, quad_error = quad(lambda xi: vk.profile(xi)*(1 - vk.profile(xi)), 0.0, 1.0)
    assert abs(value - ALPHA) <= max(quad_error, 1e-15)
    assert vk.ALPHA == ALPHA


def test_beta_is_wall_slope_within_step_halving() -> None:
    """The wall slope at h/2 is within the change from h to h/2 of BETA = g'(0)."""
    coarse, fine = (ss.wall_slope(vk.profile(np.arange(0.0, 2.0 + h/2, h)), h) for h in (0.02, 0.01))
    assert abs(fine - BETA) <= abs(coarse - fine), (
        f"g'(0): {fine - BETA:.3e} from BETA exceeds the step-halving change {coarse - fine:.3e}")
    assert vk.BETA == BETA


# (c) Table 4-1
def test_table_4_1_majdalani_xuan_row() -> None:
    """delta sqrt(Re_x)/x, C_f sqrt(Re_x), theta* = theta/delta and H = delta*/theta, to +/- 0.0005."""
    delta_star, _ = quad(lambda xi: 1 - vk.profile(xi), 0.0, 1.0)
    computed = {"delta sqrt(Re_x)/x": vk.delta(0.1, U, NU)*np.sqrt(U*0.1/NU)/0.1,
                "C_f sqrt(Re_x)": vk.C_f(1e5)*np.sqrt(1e5),
                "theta*": vk.theta(0.1, U, NU)/vk.delta(0.1, U, NU),
                "H": delta_star/vk.ALPHA}
    for name, book in TABLE_4_1.items():
        assert abs(computed[name] - book) <= HALF_LAST_DIGIT, f"{name}: {computed[name]:.6f} against {book}"


# (d) The momentum integral and the profile's boundary conditions
def test_avg_C_f_is_twice_theta_over_L() -> None:
    """Eq. 4-10: avg C_f = 2 theta(L)/L."""
    np.testing.assert_allclose(vk.avg_C_f(U*X/NU), 2*vk.theta(X, U, NU)/X, rtol=1e-14, atol=0)


def test_profile_boundary_conditions() -> None:
    """g(0) = 0, g''(0) = 0 (wall momentum, Eq. 4-20), g(1) = 1, g'(1) = 0, with the derivatives taken exactly
    on the polynomial (5 xi - 3 xi^3 + xi^4)/3, which the module's profile must equal inside the layer."""
    g = np.polynomial.Polynomial([0, 5/3, 0, -1, 1/3])
    xi = np.linspace(0.0, 1.0, 11)[:-1]
    np.testing.assert_allclose(vk.profile(xi), g(xi), rtol=1e-15, atol=1e-16)
    assert vk.profile(0.0) == 0.0 and vk.profile(1.0) == 1.0
    assert np.all(vk.profile([1.5, 2.0, 10.0, 1e80]) == 1.0)  # u = U beyond the edge
    assert g.deriv(2)(0.0) == pytest.approx(0.0, abs=1e-15)
    assert g.deriv(1)(1.0) == pytest.approx(0.0, abs=1e-15)
    assert g(1.0) == pytest.approx(1.0, abs=1e-15)


# (e) The RK4 march of delta against the closed form. The author's grid and tolerance (AI-USE.md section 4, 2026-10-27)
MARCH_X0, MARCH_X_END = 0.01, 0.5
MARCH_H = (MARCH_X_END - MARCH_X0)/64  # 7.65625e-3 m; h/2 and h/4 follow
P_OBS_TOL = 0.1


@lru_cache(maxsize=None)
def marches():
    """march_delta at h, h/2 and h/4 on the author's grid."""
    return [vk.march_delta(MARCH_X0, MARCH_X_END, U, NU, MARCH_H/2**k) for k in range(3)]


def test_march_delta_within_step_halving() -> None:
    """The error at h/4 against the closed form is within the change from h/2 to h/4 on their shared points."""
    (_, delta_h2), (x_h4, delta_h4) = marches()[1:]
    error = np.max(np.abs(delta_h4 - np.sqrt(2*NU*BETA*x_h4/(U*ALPHA))))
    change = np.max(np.abs(delta_h2 - delta_h4[::2]))
    assert error <= change, f"error at h/4 {error:.3e} exceeds the h/2 to h/4 change {change:.3e}"


def test_march_delta_observed_order() -> None:
    """Oberkampf's p_obs = log2(|delta_h - delta_h/2| / |delta_h/2 - delta_h/4|) on the shared points: RK4 is 4."""
    (_, d_h), (_, d_h2), (_, d_h4) = marches()
    p_obs = np.log2(np.max(np.abs(d_h - d_h2[::2]))/np.max(np.abs(d_h2 - d_h4[::2])))
    assert abs(p_obs - 4) <= P_OBS_TOL, f"p_obs = {p_obs:.3f}"


def test_march_delta_starts_from_closed_form() -> None:
    x, delta_march = vk.march_delta(MARCH_X0, MARCH_X_END, U, NU, MARCH_H)
    assert x[0] == MARCH_X0 and x[-1] == pytest.approx(MARCH_X_END, rel=1e-14)
    assert delta_march[0] == vk.delta(MARCH_X0, U, NU)


# Invalid inputs
@pytest.mark.parametrize("Re", [0.0, -1.0, np.nan, np.inf, [], [1e5, -1.0], np.nextafter(1e6, np.inf)])
@pytest.mark.parametrize("function", [vk.C_f, vk.avg_C_f])
def test_rejects_re_outside_range(function, Re) -> None:
    with pytest.raises(ValueError, match="must be finite and in"):
        function(Re)


@pytest.mark.parametrize("x, U_, nu", [(0.0, U, NU), (X, 0.0, NU), (X, U, -NU), (np.nan, U, NU), (1.0, U, NU)])
@pytest.mark.parametrize("function", [vk.delta, vk.theta])
def test_thickness_rejects_invalid_inputs(function, x, U_, nu) -> None:
    """x, U and nu must be finite and positive, and U*x/nu <= 1e6 (x = 1 m gives 1.9e6)."""
    with pytest.raises(ValueError, match="must be finite and in"):
        function(x, U_, nu)


@pytest.mark.parametrize("xi", [-0.1, np.nan, np.inf, -np.inf, []])
def test_profile_rejects_invalid_xi(xi) -> None:
    with pytest.raises(ValueError, match="xi must be finite and >= 0"):
        vk.profile(xi)


@pytest.mark.parametrize("x0, x_end, U_, nu, h, match", [
    (0.0, 0.5, U, NU, 0.1, "x0 must be finite"),
    (0.5, 0.1, U, NU, 0.1, "x_end must be greater than x0"),
    (0.1, 0.5, U, NU, 0.3, "whole number of steps"),
    (0.1, 1.0, U, NU, 0.1, "Re_x"),
    ([0.1], 0.5, U, NU, 0.1, "must be a scalar"),
    (0.1, 0.5, U, NU, 0.0, "h must be finite"),
    (0.1, 0.5, U, NU, -0.1, "h must be finite"),
    (0.1, 0.5, 0.0, NU, 0.1, "U must be finite"),
    (0.1, 0.5, U, -NU, 0.1, "nu must be finite"),
])
def test_march_delta_rejects_invalid_inputs(x0, x_end, U_, nu, h, match) -> None:
    with pytest.raises(ValueError, match=match):
        vk.march_delta(x0, x_end, U_, nu, h)
