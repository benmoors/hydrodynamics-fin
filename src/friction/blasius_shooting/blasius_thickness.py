from functools import lru_cache

import numpy as np
import pandas as pd

from src.friction.blasius_shooting.shooting_blasius import (ETA_ARRAY, GUESS2_ddf, GUESS_ddf, INITIAL_df, INITIAL_f,
                                                            STEP_SIZE, F, blasius_rhs, rk4_solve, secant_for_shooting,
                                                            white_df, white_eta)

# The 99 % edge: u/U = f' = 0.99
EDGE = 0.99

# Limit: eta_max (about 9.970, the end of the RK4 grid) stands in for infinity in delta* and theta.
# Limit: theta uses the trapezoidal rule at the RK4 step, about 2e-4 low, which shows in theta and H.
# Limit: the profile is the default-tolerance shot (|F| < 1e-6), and laminar Blasius only.


@lru_cache(maxsize=None)
def blasius_coefficients():
    """Thickness coefficients of the Blasius layer, from the RK4 shooting profile.

    Each thickness is a coefficient times x/sqrt(Re_x), in the scaling eta = y*sqrt(U/(nu*x)),
    f''' + 1/2 f f'' = 0, where u/U = f'. The shot runs once, on the first call.

    Returns
    -------
    a : float
        delta_99*sqrt(Re_x)/x = eta_99, where f'(eta_99) = 0.99. Found with the secant method on one
        partial RK4 step from the last grid point below the edge.
    c : float
        delta**sqrt(Re_x)/x = eta_max - f(eta_max), the integral of (1 - f') from 0 to eta_max.
    d : float
        theta*sqrt(Re_x)/x = h/2 * sum(f_i'(1 - f_i') + f_{i+1}'(1 - f_{i+1}')), the trapezoidal rule
        on the RK4 grid from 0 to eta_max, with h = STEP_SIZE.
    H : float
        Shape factor delta*/theta = c/d.
    """
    s_star, _, _, _ = secant_for_shooting(F, GUESS_ddf, GUESS2_ddf)
    BLASIUS_RK4 = rk4_solve(blasius_rhs, [INITIAL_f, INITIAL_df, s_star], ETA_ARRAY, STEP_SIZE)
    f = BLASIUS_RK4[:, 0]
    df = BLASIUS_RK4[:, 1]

    # eta_99: one partial RK4 step of length delta from node k, the last point with f' < 0.99
    k = np.searchsorted(df, EDGE) - 1

    def edge_residual(delta):
        return rk4_solve(blasius_rhs, BLASIUS_RK4[k], [ETA_ARRAY[k], ETA_ARRAY[k] + delta], delta)[-1][1] - EDGE

    delta, _, _, _ = secant_for_shooting(edge_residual, 0.0, STEP_SIZE, precision=1e-12)
    a = ETA_ARRAY[k] + delta

    c = ETA_ARRAY[-1] - f[-1]
    h = STEP_SIZE
    d = h/2*np.sum(df[:-1]*(1 - df[:-1]) + df[1:]*(1 - df[1:]))
    return a, c, d, c/d


def thicknesses(Re_x):
    """Blasius boundary-layer thicknesses over x at the given local Reynolds numbers.

    Parameters
    ----------
    Re_x : float or array_like
        Local Reynolds number U*x/nu, dimensionless: one value or a non-empty 1-D array. Every value
        must be finite and > 0. The Blasius layer is laminar, so the results only describe a real flow
        below transition.

    Returns
    -------
    delta_over_x : numpy.ndarray
        Shape (n, 3), one row per Re_x: delta_99/x, delta*/x and theta/x, each a coefficient from
        blasius_coefficients() divided by sqrt(Re_x).
    H : float
        Shape factor delta*/theta, the same at every Re_x.

    Raises
    ------
    ValueError
        If Re_x is not numeric, empty or more than 1-D, or any value is not finite or not positive.
    """
    Re_x = np.atleast_1d(np.asarray(Re_x))
    # A bool would pass as 1.0
    if Re_x.dtype.kind not in "iuf":
        raise ValueError("Re_x must be a number or an array of numbers (a bool is not)")
    Re_x = Re_x.astype(float)
    if Re_x.ndim != 1 or Re_x.size == 0:
        raise ValueError("Re_x must be one value or a non-empty 1-D array")
    if not np.all(np.isfinite(Re_x) & (Re_x > 0)):
        raise ValueError("Re_x must be finite and positive")
    a, c, d, H = blasius_coefficients()
    return np.array([a, c, d])/np.sqrt(Re_x)[:, None], H


if __name__ == "__main__":
    a, c, d, H = blasius_coefficients()

    # White and Majdalani (2022): Table 4-3 edge row (the 99 % edge, footnote value), and Table 4-4, p.175.
    # Table 4-4 is the exact Blasius solution, integrated to infinity.
    edge = np.argmin(np.abs(white_df - EDGE))  # the edge row is the one where f' = 0.99
    comparison = pd.DataFrame(
        [["eta_99", a, white_eta[edge], "Table 4-3 edge row"],
         ["delta_99 sqrt(Re_x)/x", a, 4.90999, "Table 4-4"],
         ["delta*/delta_99", c/a, 0.35047, "Table 4-4"],
         ["theta/delta_99", d/a, 0.13526, "Table 4-4"],
         ["H", H, 2.59110, "Table 4-4"]],
        columns=["quantity", "computed", "White", "source"])
    comparison["difference"] = comparison["computed"] - comparison["White"]
    comparison["relative difference"] = comparison["difference"]/comparison["White"]
    with pd.option_context("display.precision", 9, "display.width", 120):
        print(comparison.to_string(index=False))
