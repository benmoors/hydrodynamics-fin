"""Forward model of the board's speed along a wave face, V(t), from the live solver's forces at one attitude.

One degree of freedom along the face, the author's E15:

    dV/dt = f(t, V) = g sin(theta(t)) - D(V, theta)/m,    D = k F_f(V) + P(V, theta) + R(V, theta)

with the face slope ramped linearly in time, the author's E16:

    theta(t) = theta_start + (theta_end - theta_start) t/T

F_f is friction_force.F_f, the author's friction law (Blasius laminar run, SWD's turbulent closure) on the live
solver's wetted area and length, and k scales it. P and R are SWD's planing and rail drag at the same attitude, read
from the live solver at each slope and interpolated in V and theta, never extrapolated. Gravity is the separate
g sin(theta) term: SWD's drag_total_n already contains -W sin(theta) at a non-zero slope, so it is never used as a
force here. A positive slope is downhill: drag_total_n = F + P + R - W sin(theta) in SWD's own rows.

Derivation of E15 and E16: Benjamin Moors, the author's own (AI-USE.md section 4, 2026-10-27). In his E16 the ramp
runs from theta_min to theta_max; it is written here from theta_start to theta_end because his ramp descends.

RK4 is the author's rk4_solve (blasius-shooting/shooting_blasius.py, from MMA3001 notebook 7.4), called one step at a
time so that a run can stop where V leaves the force data.

Usage
-----
    >>> import forward_model as fm
    >>> t, V, a, complete = fm.simulate()          # the author's run: 20 -> 0 deg over 3 s from 6 m/s
    >>> t, V, a, complete = fm.simulate(V0=6.5, k=1.1)
    >>> forces = fm.load_forces()
    >>> forces.D(7.0, 10.0, 1.0)                   # N, at 7 m/s on a 10 deg slope
"""

import sys
from functools import lru_cache
from pathlib import Path
from typing import Callable, NamedTuple

import numpy as np
import pandas as pd
from scipy.interpolate import PchipInterpolator

FRICTION_DIR = Path(__file__).resolve().parents[1] / "friction-function"
for folder in (FRICTION_DIR, FRICTION_DIR / "blasius-shooting"):
    if str(folder) not in sys.path:
        sys.path.insert(0, str(folder))

import friction_force as ff  # noqa: E402
from shooting_blasius import rk4_solve  # noqa: E402

G = 9.81
# The weight the live solver trimmed lift to (SWD/data/live_solver/README.md); m is the mass that weight implies
WEIGHT_N = 802.21
MASS_KG = WEIGHT_N/G

# The author's run (AI-USE.md section 4, 2026-10-27): attitude, slope ramp, run length, starting speed and step.
# h = 0.001 s: V moves by at most 1.8e-12 m/s from h = 0.002 s over the shared nodes (3.3e-13 m/s at t = 3 s), at
# about 6 s per run
POS_Y, POS_X = 0.0, 0.45
THETA_START, THETA_END = 20.0, 0.0
T_RUN = 3.0
V0_RUN = 6.0
H = 0.001

# SWD's decomposition on the 0 deg rows: drag_total_n within 1 % of friction + planing + rail (the screens' rule)
DECOMP_TOL = 0.01
# On the other slopes the weight term is in drag_total_n: |drag_total - (F + P + R - W sin(theta))| <= SLOPE_TOL, N.
# The author's 25 N passes every row at pos_x 0.45, including the (2 m/s, -10 deg) outlier
SLOPE_TOL = 25.0

# Limit: one attitude (pos_y 0, pos_x 0.45) at drift 0; a 1-D model along the face, with no roll, yaw or pitch.
# Limit: the forces exist only on the live solver's grid, 2-10 m/s and -10 to 20 deg; nothing is extrapolated, and a
#        run stops where V leaves it.
# Limit: F_f uses the wetted area and length of the 0 deg rows; load_forces checks they are the same at every slope.
# Limit: SWD's rows do not decompose exactly. At pos_x 0.45 the 0 deg rows miss F + P + R by 0.37-0.73 %. At non-zero
#        slopes, drag_total - (F + P + R - W sin(theta)) is within 4.3 N up to 15 deg, up to -10.2 N at 20 deg, and
#        -22.1 N at (2 m/s, -10 deg). The model uses F_f, P and R, so this is a gap in SWD's data, not in E15.
# Limit: V* at a constant 10 deg is 7.306 m/s here; SWD's own drag_total_n crosses zero at 7.293 m/s (linear between
#        7 and 8 m/s). The 0.013 m/s gap comes from F_f being about 0.6-0.7 N below friction_n and from the residual
#        above.


class OutOfData(Exception):
    """V or theta is outside the force data; march stops the run here (it is not a ValueError on purpose)."""


class Forces(NamedTuple):
    """The resistance at one attitude and the ranges it is defined on."""

    D: Callable[[float, float, float], float]
    v_range: tuple
    theta_range: tuple


@lru_cache(maxsize=None)
def load_forces(path=ff.SOLVER_CSV, pos_y=POS_Y, pos_x=POS_X, slope_tol=SLOPE_TOL):
    """The resistance D(V, theta, k) = k F_f(V) + P(V, theta) + R(V, theta) at one live-solver attitude.

    P + R is a PCHIP in speed at each slope, then a PCHIP in slope through those values. Neither extrapolates.

    Parameters
    ----------
    path : pathlib.Path, optional
        The live solver's converged ``solver_points.csv``.
    pos_y, pos_x : float, optional
        The attitude (SWD scan position). Default the author's, 0 and 0.45.
    slope_tol : float, optional
        N, > 0. Largest accepted |drag_total_n - (F + P + R - W sin(theta))| on the non-zero slopes. Default
        SLOPE_TOL.

    Returns
    -------
    Forces
        ``D(V, theta, k)`` in N, for V in m/s, theta in degrees and k >= 0; raises OutOfData outside ``v_range``
        (m/s) or ``theta_range`` (deg), and ValueError if V, theta or k is not a finite scalar or k < 0.

    Raises
    ------
    ValueError
        If slope_tol is not a finite scalar > 0, the attitude's drift-0 rows are not a complete speed x slope grid, a
        0 deg row fails the 1 % check, a non-zero slope row fails slope_tol, or the wetted area or length changes
        with slope.
    """
    if _scalar("slope_tol", slope_tol) <= 0:
        raise ValueError("slope_tol must be > 0")
    data = pd.read_csv(path)
    rows = data[(data.drift_deg == 0) & (data.pos_y == pos_y) & (data.pos_x == pos_x)]
    if rows.duplicated(["speed_ms", "slope_deg"]).any():
        raise ValueError(f"repeated (speed, slope) rows at pos_y {pos_y}, pos_x {pos_x}")
    speeds, slopes = np.sort(rows.speed_ms.unique()), np.sort(rows.slope_deg.unique())
    if len(speeds) < 2 or len(slopes) < 2 or len(rows) != len(speeds)*len(slopes):
        raise ValueError(f"the speed x slope grid at pos_y {pos_y}, pos_x {pos_x} is not complete")

    parts = rows.friction_n + rows.fx_planing_n + rows.fx_rail_n
    level = rows.slope_deg == 0
    bad = level & ((rows.drag_total_n - parts).abs() > DECOMP_TOL*rows.drag_total_n.abs())
    # At a non-zero slope drag_total_n also carries the weight component: positive slope is downhill
    bad |= ~level & ((rows.drag_total_n - (parts - WEIGHT_N*np.sin(np.radians(rows.slope_deg)))).abs() > slope_tol)
    if bad.any():
        failed = list(zip(rows.speed_ms[bad], rows.slope_deg[bad]))
        raise ValueError(f"decomposition check failed at (speed m/s, slope deg) {failed}")
    if (rows.groupby("speed_ms")[["wetted_area_m2", "wetted_length_mm"]].nunique() > 1).any(axis=None):
        raise ValueError("the wetted area or length changes with slope, so the 0 deg F_f does not hold")

    grid = rows.pivot(index="speed_ms", columns="slope_deg", values="fx_planing_n") \
        + rows.pivot(index="speed_ms", columns="slope_deg", values="fx_rail_n")
    # One PCHIP in speed per slope column, all at once; the slope direction is done per call
    # ponytail: the slope PCHIP is rebuilt on every call (~0.27 ms of ~0.43 ms per D); a 3 s run at h = 0.001 s takes
    #           ~6 s. Cache the Fritsch-Carlson slopes per V if Step 3's fits need the speed.
    pr_in_V = PchipInterpolator(speeds, grid.loc[speeds, slopes].to_numpy(dtype=float), axis=0, extrapolate=False)
    A, L = ff.wetted_geometry(path, pos_y, pos_x)
    v_lo, v_hi, th_lo, th_hi = speeds[0], speeds[-1], slopes[0], slopes[-1]

    def D(V, theta_deg, k):
        """Resistance, N, at V m/s and theta deg for k >= 0; OutOfData outside the grid, ValueError if not finite."""
        # A NaN is a numerical failure, not a run leaving the data, so it must not reach the OutOfData stop
        V, theta_deg, k = _scalar("V", V), _scalar("theta_deg", theta_deg), _scalar("k", k)
        if k < 0:
            raise ValueError("k must be >= 0")
        if not (v_lo <= V <= v_hi and th_lo <= theta_deg <= th_hi):
            raise OutOfData(f"V {V} m/s, theta {theta_deg} deg is outside {v_lo}-{v_hi} m/s, {th_lo}-{th_hi} deg")
        return k*float(ff.F_f(V, A, L)) + float(PchipInterpolator(slopes, pr_in_V(V))(theta_deg))

    return Forces(D, (float(v_lo), float(v_hi)), (float(th_lo), float(th_hi)))


def theta(t, theta_start, theta_end, T):
    """The slope ramp, E16: theta(t) = theta_start + (theta_end - theta_start) t/T, degrees.

    Parameters
    ----------
    t : float or array_like
        Time, s, finite and in [0, T]. RK4's last trial stage at t_i + h can round past T, so a slack of 1e-9 T is
        accepted at either end and t/T is clipped to [0, 1].
    theta_start, theta_end : float
        Slope at t = 0 and t = T, degrees, finite.
    T : float
        Ramp time, s, finite and > 0.

    Returns
    -------
    float or numpy.ndarray
        theta, degrees, the same shape as t.

    Raises
    ------
    ValueError
        If T, theta_start or theta_end is not a finite scalar, T is not positive, t is empty or not numeric (a bool
        is not), or t is not finite or outside [0, T] by more than the slack.
    """
    T, theta_start, theta_end = _scalar("T", T), _scalar("theta_start", theta_start), _scalar("theta_end", theta_end)
    if T <= 0:
        raise ValueError("T must be > 0")
    t = np.asarray(t)
    # A bool would pass as 0 or 1 s, and an empty array would return an empty theta without complaint
    if t.size == 0 or t.dtype.kind not in "iuf":
        raise ValueError("t must be a number or a non-empty array of numbers")
    t = t.astype(float)
    if not np.all(np.isfinite(t) & (t >= -1e-9*T) & (t <= T*(1 + 1e-9))):
        raise ValueError("t must be finite and in [0, T]")
    return theta_start + (theta_end - theta_start)*np.clip(t/T, 0.0, 1.0)


def _scalar(name, value):
    """value as a float, or ValueError unless it is a finite real scalar (a bool or a string is not)."""
    try:
        ok = not isinstance(value, (bool, np.bool_)) and np.ndim(value) == 0 and bool(np.isfinite(value))
    except TypeError:
        ok = False
    if not ok:
        raise ValueError(f"{name} must be a finite scalar")
    return float(value)


def march(rhs, V0, T, h):
    """RK4 for dV/dt = rhs(t, [V]) from V0 on t = 0, h, ..., T, stopping where rhs raises OutOfData.

    Each step is one call of the author's rk4_solve. A run stops (A6) at the last node whose own derivative and all
    four RK4 stages stayed inside the data, so every returned node is inside it.

    Parameters
    ----------
    rhs : callable
        rhs(t, state) -> numpy.ndarray of shape (1,), dV/dt in m/s^2 for state = [V]; raises OutOfData to stop.
    V0 : float
        V at t = 0, m/s, finite.
    T : float
        Run length, s, finite and > 0.
    h : float
        Step, s, finite and > 0; T/h must be a whole number of steps.

    Returns
    -------
    t : numpy.ndarray
        Node times, s: 0, h, 2h, ..., up to T for a complete run.
    V : numpy.ndarray
        V at each node, m/s.
    a : numpy.ndarray
        dV/dt at each node, m/s^2: rhs at the node itself, not a finite difference.
    complete : bool
        True if the run reached T; False if it stopped where rhs raised OutOfData.

    Raises
    ------
    ValueError
        If V0, T or h is not a finite scalar, T or h is not positive, or T/h is not a whole number of steps.
    """
    V0, T, h = _scalar("V0", V0), _scalar("T", T), _scalar("h", h)
    if T <= 0 or h <= 0:
        raise ValueError("T and h must be > 0")
    n = round(T/h)
    if n < 1 or abs(n*h - T) > 1e-12*T:
        raise ValueError("T/h must be a whole number of steps")
    t = h*np.arange(n + 1)
    V, a = np.empty(n + 1), np.empty(n + 1)
    V[0] = V0
    for i in range(n + 1):
        try:
            # ponytail: rk4_solve recomputes this as its k1, so a step costs 5 rhs calls, not 4 (+25 %); the price of
            #           calling the author's rk4_solve unchanged
            a[i] = rhs(t[i], V[i:i + 1])[0]
        except OutOfData:
            return t[:i], V[:i], a[:i], False
        if i == n:
            break
        try:
            V[i + 1] = rk4_solve(rhs, [V[i]], t[i:i + 2], h)[1, 0]
        except OutOfData:
            # A trial stage left the data: node i is the last one inside it
            return t[:i + 1], V[:i + 1], a[:i + 1], False
    return t, V, a, True


def simulate(V0=V0_RUN, k=1.0, theta_start=THETA_START, theta_end=THETA_END, T=T_RUN, h=H, forces=None):
    """V(t) along the face from E15 and E16, by RK4.

    Parameters
    ----------
    V0 : float, optional
        Starting speed, m/s, inside the force data (2-10 m/s at the author's attitude). Default 6.
    k : float, optional
        Friction factor on F_f, dimensionless, finite and >= 0. Default 1.
    theta_start, theta_end : float, optional
        Slope at t = 0 and t = T, degrees, inside the force data (-10 to 20 deg). Default 20 and 0.
    T : float, optional
        Ramp and run length, s, > 0. Default 3.
    h : float, optional
        RK4 step, s, > 0, with T/h a whole number. Default H.
    forces : Forces, optional
        From load_forces(). Default load_forces() at the author's attitude.

    Returns
    -------
    t, V, a, complete
        As march: node times (s), V (m/s), dV/dt from E15 at each node (m/s^2), and whether the run reached T.

    Raises
    ------
    ValueError
        If any input is not a finite scalar or is outside its range, or T/h is not a whole number of steps.
    """
    forces = load_forces() if forces is None else forces
    (v_lo, v_hi), (th_lo, th_hi) = forces.v_range, forces.theta_range
    if not v_lo <= _scalar("V0", V0) <= v_hi:
        raise ValueError(f"V0 must be within the force data, {v_lo} to {v_hi} m/s")
    if _scalar("k", k) < 0:
        raise ValueError("k must be >= 0")
    for name, value in (("theta_start", theta_start), ("theta_end", theta_end)):
        if not th_lo <= _scalar(name, value) <= th_hi:
            raise ValueError(f"{name} must be within the force data, {th_lo} to {th_hi} deg")

    def rhs(t, state):
        """E15 for the state [V]."""
        slope = theta(t, theta_start, theta_end, T)
        return np.array([G*np.sin(np.radians(slope)) - forces.D(state[0], slope, k)/MASS_KG])

    return march(rhs, V0, T, h)


if __name__ == "__main__":
    t, V, a, complete = simulate()
    every = round(0.5/H)
    print(f"pos_y {POS_Y}, pos_x {POS_X}; theta {THETA_START} -> {THETA_END} deg over {T_RUN} s; V0 {V0_RUN} m/s; "
          f"k 1; h {H} s; complete: {complete}")
    print(pd.DataFrame({"t (s)": t[::every], "theta (deg)": theta(t[::every], THETA_START, THETA_END, T_RUN),
                        "V (m/s)": V[::every], "a (m/s^2)": a[::every]}).to_string(index=False,
                                                                                 float_format="{:.6g}".format))
