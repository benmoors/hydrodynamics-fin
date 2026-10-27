"""Friction drag on the board bottom, F_f(V), from the live solver's wetted area and length.

The wetted length L splits at SWD's transition point x_tr = RE_CRIT*nu/V, capped at L. The first x_tr/L of the
wetted area is laminar and the rest turbulent:

    F_f = 1/2 rho V^2 A(V) [ (x_tr/L) C_lam(Re_xtr) + (1 - x_tr/L) C_turb(Re_L) ],   Re_xtr = min(Re_L, RE_CRIT)

C_lam is the average laminar coefficient over the run 0 <= x <= x_tr, by default the Blasius avg_C_f from the RK4
shooting (blasius-shooting/skin_and_shear.py); any law of the same form, such as von-karman/von_karman.avg_C_f, can
be passed instead. C_turb = 0.031/Re_L^(1/7) is SWD's turbulent closure.

Design of F_f: Benjamin Moors, the author's own (AI-USE.md section 4, 2026-10-27).

Usage
-----
    >>> import friction_force as ff
    >>> A, L = ff.wetted_geometry()                # the live-solver screen's attitude
    >>> ff.F_f([2.0, 8.3], A, L)                   # N, Blasius laminar run
    >>> import von_karman as vk
    >>> ff.F_f(8.3, A, L, laminar_avg_C_f=vk.avg_C_f)
"""

import sys
from pathlib import Path

import numpy as np
import pandas as pd
from scipy.interpolate import PchipInterpolator

BLASIUS_DIR = Path(__file__).resolve().parent / "blasius-shooting"
if str(BLASIUS_DIR) not in sys.path:
    sys.path.insert(0, str(BLASIUS_DIR))

import skin_and_shear  # noqa: E402

# SWD's transition Reynolds number (Module_couche_limite)
RE_CRIT = 5*10**5
# SWD's salt water at 20 degC; the live solver's mass flux/(frontal section x V) gives 1025.000 at every speed
RHO = 1025.0
MU = 0.00107

SOLVER_CSV = (Path(__file__).resolve().parents[1] / "SWD" / "data" / "live_solver" / "default_shortboard" / "converged"
              / "solver_points.csv")
# The live-solver screen's attitude (SWD/model/identifiability_screen_live.py): slope 0, drift 0
POS_Y, POS_X = 0.0, 0.45

# Limit: at a fixed attitude the live solver's wetted area and length are constant in speed (all 1,276 of the
#        1,354 converged attitudes that have two or more speeds), so A(V) and L(V) are flat: there is no shrinking
#        wetted area with speed, and all of F_f's speed dependence comes from the friction law.
# Limit: flat plate, zero pressure gradient, smooth wall (SWD's rough-wall branch, Ra > 50 micron, is not here).


def wetted_geometry(path=SOLVER_CSV, pos_y=POS_Y, pos_x=POS_X, slope_deg=0.0, drift_deg=0.0):
    """Wetted area A(V) and wetted length L(V) at one live-solver attitude, as PCHIP interpolants in speed.

    Parameters
    ----------
    path : pathlib.Path, optional
        The live solver's converged ``solver_points.csv``.
    pos_y, pos_x : float, optional
        The attitude (SWD scan position). Default: the live-solver screen's, 0 and 0.45.
    slope_deg, drift_deg : float, optional
        Surface slope and drift, degrees. Default 0 and 0.

    Returns
    -------
    A : scipy.interpolate.PchipInterpolator
        Wetted area, m^2, against speed in m/s.
    L : scipy.interpolate.PchipInterpolator
        Wetted length, m (``wetted_length_mm``/1000), against speed in m/s.
        Neither extrapolates: outside the converged speeds both return NaN.

    Raises
    ------
    ValueError
        If the attitude has fewer than two converged speeds, or a speed appears twice.
    """
    data = pd.read_csv(path)
    rows = data[(data.slope_deg == slope_deg) & (data.drift_deg == drift_deg) & (data.pos_y == pos_y)
                & (data.pos_x == pos_x)].sort_values("speed_ms")
    if len(rows) < 2:
        raise ValueError(f"fewer than two converged speeds at pos_y {pos_y}, pos_x {pos_x}")
    speed = rows.speed_ms.to_numpy(dtype=float)
    if not np.all(np.diff(speed) > 0):
        raise ValueError(f"repeated speeds at pos_y {pos_y}, pos_x {pos_x}: one row per speed is needed")
    return (PchipInterpolator(speed, rows.wetted_area_m2.to_numpy(dtype=float), extrapolate=False),
            PchipInterpolator(speed, rows.wetted_length_mm.to_numpy(dtype=float)/1000, extrapolate=False))


def F_f(V, A, L, rho=RHO, mu=MU, laminar_avg_C_f=skin_and_shear.avg_C_f):
    """Friction drag, laminar run up to x_tr and turbulent run after it.

    Parameters
    ----------
    V : float or array_like
        Board speed through the water, m/s, finite and > 0 (from the forward model's trajectory).
    A : callable
        Wetted area A(V), m^2, e.g. from wetted_geometry().
    L : callable
        Wetted length L(V), m, e.g. from wetted_geometry().
    rho : float, optional
        Water density, kg/m^3. Default SWD's 1025.
    mu : float, optional
        Dynamic viscosity, Pa s. Default SWD's 0.00107. The kinematic viscosity nu = mu/rho is worked out here.
    laminar_avg_C_f : callable, optional
        Average laminar coefficient against Reynolds number, Re -> C. Default skin_and_shear.avg_C_f (Blasius,
        from the shooting f''(0)).

    Returns
    -------
    float or numpy.ndarray
        F_f, N, the same shape as V.

    Raises
    ------
    ValueError
        If V is empty, not finite or not positive; if A(V) or L(V) is not finite (V outside their range: they are
        not extrapolated), A(V) is negative or L(V) is not positive; if rho or mu is not a finite, positive
        scalar; or if laminar_avg_C_f rejects the laminar Reynolds number.
    """
    V = np.asarray(V, dtype=float)
    if V.size == 0 or not np.all(np.isfinite(V) & (V > 0)):
        raise ValueError("V must be finite and positive")
    area, length = np.asarray(A(V), dtype=float), np.asarray(L(V), dtype=float)
    if not np.all(np.isfinite(area) & np.isfinite(length)):
        raise ValueError("V is outside the range of A(V) and L(V), which are not extrapolated")
    if np.any(area < 0) or np.any(length <= 0):
        raise ValueError("A(V) must be >= 0 and L(V) > 0")
    if np.ndim(rho) != 0 or np.ndim(mu) != 0 or not (np.isfinite(rho) and rho > 0 and np.isfinite(mu) and mu > 0):
        raise ValueError("rho and mu must be finite and positive scalars")
    nu = mu/rho

    # Transition at SWD's Re_crit, capped at the wetted length: below RE_CRIT*nu/L the whole length is laminar
    x_tr = np.minimum(RE_CRIT*nu/V, length)
    laminar_share = x_tr/length
    Re_L = V*length/nu
    # Re at x_tr is min(Re_L, RE_CRIT) exactly; V*x_tr/nu can round one ulp above RE_CRIT
    C_lam = laminar_avg_C_f(np.minimum(Re_L, RE_CRIT))
    # SWD's closure, on the Reynolds number of the whole wetted length
    C_turb = 0.031/Re_L**(1/7)
    return 0.5*rho*V**2*area*(laminar_share*C_lam + (1 - laminar_share)*C_turb)


if __name__ == "__main__":
    A, L = wetted_geometry()
    data = pd.read_csv(SOLVER_CSV)
    swd = data[(data.slope_deg == 0) & (data.drift_deg == 0) & (data.pos_y == POS_Y)
               & (data.pos_x == POS_X)].sort_values("speed_ms")
    V = swd.speed_ms.to_numpy(dtype=float)
    table = pd.DataFrame({"V (m/s)": V, "A (m^2)": A(V), "L (m)": L(V),
                          "x_tr (m)": np.minimum(RE_CRIT*(MU/RHO)/V, L(V)), "F_f (N)": F_f(V, A, L),
                          "SWD friction_n (N)": swd.friction_n.to_numpy(dtype=float)})
    table["F_f/SWD"] = table["F_f (N)"]/table["SWD friction_n (N)"]
    print(f"pos_y {POS_Y}, pos_x {POS_X}, slope 0, drift 0; rho {RHO}, mu {MU}")
    print(table.to_string(index=False, float_format="{:.6g}".format))
    print("\nNote: F_f/SWD is a difference from SWD's own friction, not an error in either.")
