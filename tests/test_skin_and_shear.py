"""Tests for the Blasius skin friction and wall shear against White and Majdalani (2022).

(a) C_f, avg C_f and the wall shear against White's sigma (Eq. 4-64), to a tolerance that adds the book's
rounding to the measured RK4, eta_max cutoff and secant errors.
(b) wall_slope on a quartic profile with a known exact slope, to a tolerance from step-halving.
"""

from __future__ import annotations

from functools import lru_cache

import numpy as np
import pytest
from scipy.integrate import quad

from src.friction.blasius_shooting import shooting_blasius as sb
from src.friction.blasius_shooting import skin_and_shear as ss

# White and Majdalani (2022) Eq. 4-64, p.170: f''(0) in the book's scaling, eta = y sqrt(U/(2 nu x)).
# Hard-coded here, not imported, so a typo in the module cannot pass against itself.
SIGMA_BOOK = 0.46959999
WHITE = SIGMA_BOOK/np.sqrt(2)  # the wall slope in the f''' + 1/2 f f'' = 0 scaling (footnote to Eq. 4-64, p.248)

# Salt water at 20 degC, as SWD uses: rho = 1025 kg/m^3, mu = 0.00107 Pa s
RHO = 1025.0
NU = 0.00107/RHO
U = 2.0
X = np.array([0.01, 0.05, 0.1, 0.2])
RE_X = np.array([1e3, 1e4, 1e5, 1e6])


@lru_cache(maxsize=None)
def error_budget():
    """The four errors in the default shot's f''(0): book, eta_max cutoff, RK4 step and secant."""
    s10, secant = ss.shoot()
    s20, _ = ss.shoot(2*sb.ETA_MAX)
    s20_half, _ = ss.shoot(2*sb.ETA_MAX, sb.STEP_SIZE/2)
    return {"book": 0.5e-8/np.sqrt(2), "eta_max": abs(s10 - s20), "RK4": 16/15*abs(s20 - s20_half),
            "secant": secant}


@pytest.mark.parametrize("name, computed, factor", [
    ("C_f sqrt(Re_x)", lambda: ss.C_f(RE_X)*np.sqrt(RE_X), 2),
    ("avg C_f sqrt(Re_L)", lambda: ss.avg_C_f(RE_X)*np.sqrt(RE_X), 4),
], ids=["C_f", "avg_C_f"])
def test_skin_friction_against_white(name, computed, factor) -> None:
    """C_f sqrt(Re_x) = 2 sigma/sqrt(2) (Eq. 4-70) and avg C_f sqrt(Re_L) = 4 sigma/sqrt(2) (Eq. 4-71)."""
    budget = error_budget()
    difference = np.max(np.abs(computed() - factor*WHITE))
    assert difference <= factor*sum(budget.values()), (
        f"{name}: {difference:.3e} from White, budget {factor} x {sum(budget.values()):.3e} = {budget}")


def test_shear_w_against_white() -> None:
    """White's wall shear in his own scaling, mu U sigma sqrt(U/(2 nu x)) (Eqs. 4-64, 4-70), so the sqrt(2)
    between the two scalings is checked too."""
    budget = error_budget()
    white = RHO*NU*U*SIGMA_BOOK*np.sqrt(U/(2*NU*X))
    np.testing.assert_allclose(ss.shear_w(U, X, NU, RHO), white, rtol=sum(budget.values())/WHITE, atol=0,
                               err_msg=f"shear_w against White, budget {budget}")


def test_avg_C_f_is_twice_C_f_at_L() -> None:
    np.testing.assert_allclose(ss.avg_C_f(RE_X), 2*ss.C_f(RE_X), rtol=1e-15, atol=0)


def test_avg_C_f_is_mean_of_C_f_over_L() -> None:
    """(1/L) times the integral of C_f(U x/nu) from 0 to L, by quad, checks the 4 in avg C_f."""
    L = X[-1]
    mean, _ = quad(lambda x: ss.C_f(U*x/NU), 0.0, L)
    assert mean/L == pytest.approx(ss.avg_C_f(U*L/NU), rel=1e-10)


def test_shear_w_is_half_rho_U_squared_C_f() -> None:
    np.testing.assert_allclose(ss.shear_w(U, X, NU, RHO), 0.5*RHO*U**2*ss.C_f(U*X/NU), rtol=1e-14, atol=0)


def test_passed_s_star_is_used() -> None:
    assert ss.C_f(1e4, s_star=0.5) == pytest.approx(2*0.5/100)
    assert ss.avg_C_f(1e4, s_star=0.5) == pytest.approx(4*0.5/100)
    assert ss.shear_w(U, X, NU, RHO, s_star=0.5) == pytest.approx(0.5*RHO*U**2*2*0.5/np.sqrt(U*X/NU))


def test_accepts_re_at_upper_bound() -> None:
    assert np.isfinite(ss.C_f(ss.RE_MAX)) and np.isfinite(ss.avg_C_f(ss.RE_MAX))


@pytest.mark.parametrize("Re", [0.0, -1.0, np.nan, np.inf, [], [1e5, -1.0], np.nextafter(1e6, np.inf)])
@pytest.mark.parametrize("function", [ss.C_f, ss.avg_C_f])
def test_rejects_re_outside_range(function, Re) -> None:
    """Re must be finite and in (0, 1e6]."""
    with pytest.raises(ValueError):
        function(Re)


@pytest.mark.parametrize("U_, x, nu, rho, s_star", [
    (U, 0.0, NU, RHO, None),
    (U, X, 0.0, RHO, None),
    (U, X, -NU, RHO, None),
    (U, X, NU, 0.0, None),
    (np.nan, X, NU, RHO, None),
    (U, 1.0, NU, RHO, None),  # U*x/nu = 1.9e6, above RE_MAX
    (U, X, NU, RHO, 0.0),
    (U, X, NU, RHO, -0.3),
])
def test_shear_w_rejects_invalid_inputs(U_, x, nu, rho, s_star) -> None:
    with pytest.raises(ValueError):
        ss.shear_w(U_, x, nu, rho, s_star=s_star)


# (b) The Majdalani-Xuan quartic, g = (5 xi - 3 xi^3 + xi^4)/3 and g = 1 beyond xi = 1, with g'(0) = 5/3
def quartic(xi):
    return np.where(xi < 1, (5*xi - 3*xi**3 + xi**4)/3, 1.0)


def test_wall_slope_on_quartic_within_step_halving() -> None:
    """The error at h/2 is within the change from h to h/2."""
    coarse, fine = (ss.wall_slope(quartic(np.arange(0.0, 2.0 + h/2, h)), h) for h in (0.02, 0.01))
    assert abs(fine - 5/3) <= abs(coarse - fine), (
        f"g'(0): error {fine - 5/3:.3e} exceeds the step-halving change {coarse - fine:.3e}")


def test_wall_slope_exact_on_quadratic() -> None:
    """The 3-point stencil is exact on 2 xi - xi^2 (White Table 4-1, g'(0) = 2); a 2-point one is not."""
    h = 0.1
    xi = np.arange(0.0, 1.0 + h/2, h)
    assert ss.wall_slope(2*xi - xi**2, h) == pytest.approx(2.0, abs=1e-12)


@pytest.mark.parametrize("df, h", [([0.0, 1.0], 0.1), ([0.0, np.nan, 1.0], 0.1), ([[0.0, 0.1, 0.2]], 0.1),
                                   ([0.0, 0.1, 0.2], 0.0), ([0.0, 0.1, 0.2], -0.1)])
def test_wall_slope_rejects_invalid_inputs(df, h) -> None:
    """Fewer than 3 points, a non-finite one, a 2-D profile, or h <= 0."""
    with pytest.raises(ValueError):
        ss.wall_slope(df, h)
