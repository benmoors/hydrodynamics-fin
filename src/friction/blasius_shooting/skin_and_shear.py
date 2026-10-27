from functools import lru_cache

import numpy as np
import pandas as pd

from src.friction.blasius_shooting.shooting_blasius import (ETA_0, ETA_MAX, GUESS2_ddf, GUESS_ddf, STEP_SIZE, F,
                                                            secant_for_shooting)

# Secant precision, in this module only: shooting_blasius keeps TOLERANCE = 1e-6
PRECISION = 1e-9
# Laminar range 0 < Re <= 1e6: laminar layers become unstable at Re_x = O(10^6) (White and Majdalani, p.165)
RE_MAX = 1e6
# White and Majdalani (2022) Eq. 4-64, p.170: f''(0) to eight digits in the book's scaling,
# eta = y*sqrt(U/(2 nu x)), f''' + f f'' = 0. In this module's scaling it is SIGMA/sqrt(2).
SIGMA = 0.46959999

# Note: SIGMA is rounded at its 8th digit, so it can be up to 5e-9 out (5e-9/sqrt(2) = 3.5e-9 in f''(0) here).
# Note: against Abbasbandy and Bervillier's 0.469599988361013 (also p.170) it is 1.6e-9 high, more than the
#       shot's own error at eta_max = 20 and h/2, so a comparison there is limited by the book's rounding.
# Limit: the laminar Blasius layer only (flat plate, zero pressure gradient, below transition).
# Limit: below Re_L ~ 1000 full Navier-Stokes drag exceeds the boundary-layer value (p.172); not enforced.


@lru_cache(maxsize=None)
def shoot(eta_max=ETA_MAX, h=STEP_SIZE):
    """f''(0) by RK4 shooting on 0 <= eta < eta_max, the secant stopping at |F| < PRECISION.

    Parameters
    ----------
    eta_max : float, optional
        End of the grid, standing in for infinity. Defaults to shooting_blasius.ETA_MAX, 10.
    h : float, optional
        RK4 step. Defaults to STEP_SIZE, 0.1/sqrt(2).

    Returns
    -------
    s_star : float
        f''(0) in the scaling eta = y*sqrt(U/(nu*x)), f''' + 1/2 f f'' = 0.
    secant_error : float
        The step one more secant iteration would take, |F_n (s_n - s_{n-1})/(F_n - F_{n-1})|: the estimate
        of how far s_star is from the root of F because the secant stopped.
    """
    eta = np.arange(ETA_0, eta_max, h)
    s_star, _, s_history, f_history = secant_for_shooting(lambda s: F(s, eta, h), GUESS_ddf, GUESS2_ddf,
                                                          precision=PRECISION)
    secant_error = abs(f_history[-1]*(s_history[-1] - s_history[-2])/(f_history[-1] - f_history[-2]))
    return s_star, secant_error


def _check(name, value, upper=np.inf):
    """value as a float array, or ValueError unless it is non-empty, finite and 0 < value <= upper."""
    value = np.asarray(value, dtype=float)
    if value.size == 0 or not np.all(np.isfinite(value) & (value > 0) & (value <= upper)):
        raise ValueError(f"{name} must be finite and in (0, {upper:g}]")
    return value


def _s_star(s_star):
    return shoot()[0] if s_star is None else _check("s_star", s_star)


def C_f(Re_x, s_star=None):
    """Local skin-friction coefficient of the Blasius layer, C_f = 2 f''(0)/sqrt(Re_x).

    Parameters
    ----------
    Re_x : float or array_like
        Local Reynolds number U*x/nu, dimensionless, finite, 0 < Re_x <= RE_MAX.
    s_star : float, optional
        f''(0). Defaults to the shooting value, shoot()[0].

    Returns
    -------
    float or numpy.ndarray
        C_f = 2*shear_w/(rho*U**2), dimensionless, the same shape as Re_x.

    Raises
    ------
    ValueError
        If Re_x is empty, not finite or outside (0, RE_MAX], or s_star is not finite and positive.
    """
    Re_x = _check("Re_x", Re_x, RE_MAX)
    return 2*_s_star(s_star)/np.sqrt(Re_x)


def avg_C_f(Re_L, s_star=None):
    """Average skin-friction coefficient over the wetted length L, avg C_f = 4 f''(0)/sqrt(Re_L).

    The mean of C_f over 0 <= x <= L on one side of the plate, equal to 2*C_f at x = L.

    Parameters
    ----------
    Re_L : float or array_like
        Reynolds number on the wetted length, U*L/nu, dimensionless, finite, 0 < Re_L <= RE_MAX.
    s_star : float, optional
        f''(0). Defaults to the shooting value, shoot()[0].

    Returns
    -------
    float or numpy.ndarray
        avg C_f, dimensionless, the same shape as Re_L.

    Raises
    ------
    ValueError
        If Re_L is empty, not finite or outside (0, RE_MAX], or s_star is not finite and positive.
    """
    Re_L = _check("Re_L", Re_L, RE_MAX)
    return 4*_s_star(s_star)/np.sqrt(Re_L)


def shear_w(U, x, nu, rho, s_star=None):
    """Wall shear stress of the Blasius layer, shear_w = rho*nu*U*f''(0)*sqrt(Re_x)/x.

    Re_x = U*x/nu is worked out here from the inputs. rho*nu is the dynamic viscosity mu, and the result
    equals 1/2*rho*U**2*C_f(Re_x).

    Parameters
    ----------
    U : float or array_like
        Free-stream speed, m/s, > 0.
    x : float or array_like
        Distance from the leading edge, m, > 0 (the shear is infinite at x = 0).
    nu : float or array_like
        Kinematic viscosity, m^2/s, > 0.
    rho : float or array_like
        Density, kg/m^3, > 0.
    s_star : float, optional
        f''(0). Defaults to the shooting value, shoot()[0].

    Returns
    -------
    float or numpy.ndarray
        Wall shear stress, Pa, broadcast over the inputs.

    Raises
    ------
    ValueError
        If any input is empty, not finite or not positive, or U*x/nu is above RE_MAX.
    """
    U, x, nu, rho = (_check(name, value) for name, value in (("U", U), ("x", x), ("nu", nu), ("rho", rho)))
    Re_x = _check("Re_x = U*x/nu", U*x/nu, RE_MAX)
    return rho*nu*U*_s_star(s_star)*np.sqrt(Re_x)/x


def wall_slope(df, h):
    """Slope at the wall of a profile sampled on an even grid, (-3 df_0 + 4 df_1 - df_2)/(2h).

    The second-order one-sided difference fd_blasius.py uses for f''(0). For a profile u/U = g(y/delta)
    the wall shear is mu*U*g'(0)/delta.

    Parameters
    ----------
    df : array_like
        The profile, u/U, at the wall and the points after it; at least 3 values.
    h : float
        Grid step, > 0.

    Returns
    -------
    float
        The slope d(df)/d(eta) at the wall.

    Raises
    ------
    ValueError
        If df is not 1-D with at least 3 values, its first 3 are not finite, or h is not finite and positive.
    """
    df = np.asarray(df, dtype=float)
    if df.ndim != 1 or df.size < 3 or not np.all(np.isfinite(df[:3])):
        raise ValueError("df must be 1-D, with at least 3 values and the first 3 finite")
    return (-3*df[0] + 4*df[1] - df[2])/(2*_check("h", h))


if __name__ == "__main__":
    h = STEP_SIZE
    cases = [(ETA_MAX, h), (2*ETA_MAX, h), (2*ETA_MAX, h/2)]
    s = np.array([shoot(eta_max, step)[0] for eta_max, step in cases])
    white = SIGMA/np.sqrt(2)

    # Settle: eta_max doubled, then h halved, as for f''(0) in rk4_blasius_checks_cc.ipynb
    table = pd.DataFrame({"eta_max": [eta_max for eta_max, _ in cases], "h": [step for _, step in cases],
                          "f''(0)": s, "C_f sqrt(Re_x)": 2*s, "avg C_f sqrt(Re_L)": 4*s,
                          "change in f''(0)": np.r_[np.nan, np.diff(s)], "f''(0) - White": s - white})
    table.loc[len(table)] = ["White", "Eq. 4-64", white, 2*white, 4*white, np.nan, np.nan]

    # Error budget for the (10, h) shot, the one C_f, avg_C_f and shear_w use. RK4: Richardson with p = 4.
    budget = pd.Series({"book: SIGMA rounded at 8 digits, 0.5e-8/sqrt(2)": 0.5e-8/np.sqrt(2),
                        "eta_max cutoff: |s(10, h) - s(20, h)|": abs(s[0] - s[1]),
                        "RK4 step: 16/15 |s(20, h) - s(20, h/2)|": 16/15*abs(s[1] - s[2]),
                        "secant: next step at (10, h)": shoot()[1]})
    check = pd.DataFrame([[name, factor*abs(s[0] - white), factor*budget.sum()]
                          for name, factor in (("f''(0)", 1), ("C_f sqrt(Re_x)", 2), ("avg C_f sqrt(Re_L)", 4))],
                         columns=["quantity", "|(10, h) - White|", "budget"])
    check["within"] = check["|(10, h) - White|"] <= check["budget"]

    small = {"change in f''(0)": "{:.3e}".format, "f''(0) - White": "{:.3e}".format}
    with pd.option_context("display.precision", 12, "display.width", 160):
        print(table.to_string(index=False, formatters=small))
        print()
        print(pd.concat([budget, pd.Series({"total": budget.sum()})]).to_string(float_format="{:.3e}".format))
        print()
        print(check.to_string(index=False, float_format="{:.3e}".format))
    print("\nNote: |(10, h) - White| is a difference from the rounded SIGMA, not the true error. SIGMA is 1.6e-9 above "
          "Abbasbandy and Bervillier's 0.469599988361013 (p.170), more than the (20, h/2) shot's own error.")
