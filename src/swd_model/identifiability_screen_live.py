"""Second identifiability screen: forces from ONE live-solver attitude, lift trimmed to the weight.

FEASIBILITY SCREEN ONLY. Nothing in this file is the project's forward model, and it must not be
reused or described as one. It asks one question of the data already in hand: could an inverse
fit recover a friction multiplier ``k`` from ~15 Hz along-path acceleration, using forces from a
single board attitude whose lift SWD's live solver held at the weight?

It re-runs the first screen, because that one took its forces from the first trajectory model's
``load_polar()``, which sums 7-12 scan positions per roll case (AI-USE.md section 5, E133). Both
left the repository with Part A on 2026-10-28; the helpers this screen took from the first one
(the mmc1 parser, sample times, noise bounds, metrics and palette) are copied here unchanged.
Here the forces are one attitude's own: SWD's live solver, slope 0, drift 0, converged
reads only. The model is a straight run at that one attitude::

    D(V)      = k * friction(V) + planing(V) + rail(V)        (PCHIP in speed, never extrapolated)
    m dV/dt   = m g sin(SLOPE_DEG) - D(V)

and only the along-path acceleration ``a_x`` is compared: lift is held at the weight, so ``a_z``
is zero, and ``a_y = V^2/R = g tan(phi)`` carries no friction information (Eq 64).

The attitude and the starting speed are chosen by fixed rules (steps 2 and 3 of the brief).
Both are provisional, pending the author's review. Nothing here gives a pass/fail verdict.

Run
---
    python -m src.swd_model.identifiability_screen_live        # from the repository root
"""

from __future__ import annotations

import sys
import time
import zipfile
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import pandas as pd
from scipy.integrate import solve_ivp
from scipy.interpolate import PchipInterpolator, PPoly
from scipy.optimize import brentq, least_squares

# The author's settings. Do not change them without asking.
PLANTED = 1.10
FRICTION_SHIFT = 0.10
V0_SHIFT = 0.20
SLOPE_DEG = 10.0

G = 9.81  # as in the first screen
WEIGHT_N = 802.21  # the live solver's weight plateau, SWD/data/live_solver/README.md
MASS_KG = WEIGHT_N / G

SOLVER_CSV = (Path(__file__).resolve().parents[2] / "SWD" / "data" / "live_solver" / "default_shortboard" / "converged"
              / "solver_points.csv")
BOARD_DIR = Path(__file__).resolve().parents[2] / "SWD" / "data" / "default_shortboard"
OUT_DIR = BOARD_DIR / "computed-data" / "identifiability_screen_live"
MMC1 = Path(__file__).resolve().parents[2] / "SWD" / "data" / "paper-supplementary" / "mmc1.zip"
MMC1_COLUMNS = ["t_ms", "sg1", "sg2", "sg3", "sg4", "sg5",
                "ax_g", "ay_g", "az_g", "rx", "ry", "rz"]

# Quiet window confirmed by the author on 2026-10-24: 20 samples from index 22
# (t = 1.498-2.795 s). It includes real motion, so its sigma is an UPPER bound on noise.
QUIET_LENGTH = 20
QUIET_START = 22
# The LOWER bound: mmc1 prints acceleration to 0.01 g, and uniform quantisation of a
# step q has standard deviation q / sqrt(12).
RESOLUTION_SIGMA = 0.01 * G / np.sqrt(12.0)

DECOMP_TOL = 0.01  # step 1: components must sum to the total within 1 %
V0_STEP = 0.1
RTOL, RTOL_CHECK, ATOL = 1e-10, 1e-11, 1e-12
EDGE_TOL = 1e-9  # m/s: how far round-off may put V outside the range at a cut
GUARD_RESIDUAL = 1e3  # residual, in sigma units, for samples a trial run never reached
DIFF_STEP = 1e-6  # finite-difference step, kept well above the ODE's rtol noise
SEED = 20261024  # the first screen's seed
N0 = 200
STD_REL_TOL = 0.05
FITS_TIMED = 5
MC_BUDGET_S = 60 * 60
HALF = 0.5  # a run covering less than this share of its duration is flagged

SHIFTED = ("k+", "k-", "v0+", "v0-")
FRICTION_RUNS, V0_RUNS = ("k+", "k-"), ("v0+", "v0-")
SIGMA_CASES = ("upper", "lower")

# Plot palette: the dataviz reference light slots 1-2 (validated: CVD dE 24.7, contrast >= 3:1).
SURFACE, INK, INK_2, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#e4e3df"
SERIES_1, SERIES_2 = "#2a78d6", "#eb6834"
BAND_UPPER, BAND_LOWER = "#ebeae6", "#cfcec8"

ASSUMPTIONS = (
    "One attitude for the whole run; the live solver's trim and attitude are not varied with speed.",
    "A path-frame model compared against board-frame IMU noise.",
    "mmc1's board, surfer and wave differ from default_shortboard with an 80 kg surfer.",
    "The noise sigma bounds are the first screen's: the author's quiet window and the 0.01 g resolution floor.",
    "Set (b) at 3 s, the window kept to match the forward model's 3 s run, depends on the optimiser's start point "
    "and on the V0 <= 10 m/s bound (about 22 % of its fits end on it), so its V0 spread is not the data's alone "
    "(the author's stated limitation, AI-USE.md section 4, 2026-10-28).",
)
READINGS = (
    "Tie-break 'median converged pos_x' is the median over the kept rows (the median over positions gives the same pick).",
    "Equilibrium speeds are reported twice: where SWD's own drag_total_n (k = 1) and where the model's D at "
    "k = PLANTED equal m g sin(SLOPE_DEG).",
    "Within one solver step that crosses a range edge, the trial stages hold the force at its edge value; the run is "
    "cut at the edge by a terminal event, so no sample is evaluated outside the converged range.",
    "Delta-a is compared only on samples covered by all five runs of a duration.",
    f"A fit trial whose run leaves the range before the last sample gets a residual of {GUARD_RESIDUAL:g} sigma on the "
    "samples it never reached; a fit whose final parameters still leave the range is counted as not converged.",
    "Mean and sd of k use converged fits; the 'within +/- FRICTION_SHIFT x PLANTED' fraction is over all draws, a "
    "non-converged fit counting as outside. Fits ending on a bound are reported separately.",
    "The 60-min Monte Carlo cap includes the timing fits; combinations run cheapest first, each allowed an equal share "
    "of the budget left, and a doubling that would overrun its share is not started ('capped').",
    f"least_squares uses diff_step = {DIFF_STEP:g} so the finite-difference Jacobian stays above the ODE's rtol noise.",
)


def load_mmc1(path: Path = MMC1) -> pd.DataFrame:
    """Parse the paper's board sample (mmc1) as ``SOURCE.md`` describes it.

    Parameters
    ----------
    path : pathlib.Path
        The archive as downloaded; it is read in place, never extracted.

    Returns
    -------
    pandas.DataFrame
        148 rows in ascending time: ``t_s`` from 0, ``sg1..sg5``, ``ax_g, ay_g, az_g``
        (g, gravity included) and the gyroscope ``rx, ry, rz``.

    Raises
    ------
    ValueError
        If any data row does not have the 12 fields.
    """
    with zipfile.ZipFile(path) as z:
        text = z.read("Board_Sample.txt").decode("ascii")
    # Every other line is a ';'-prefixed hex echo of the line above it - no new information.
    rows = [ln.split(";") for ln in text.splitlines() if ln.strip() and not ln.startswith(";")]
    bad = [i for i, r in enumerate(rows) if len(r) != len(MMC1_COLUMNS)]
    if bad:
        raise ValueError(f"mmc1 rows {bad[:5]} do not have {len(MMC1_COLUMNS)} fields")
    df = pd.DataFrame([[float(x) for x in r] for r in rows], columns=MMC1_COLUMNS)
    # The board counter (ms) runs backwards: reverse it and start the clock at zero.
    df = df.iloc[::-1].reset_index(drop=True)
    df.insert(0, "t_s", (df.t_ms - df.t_ms.iloc[0]) / 1000.0)
    return df.drop(columns="t_ms")


def sample_times(mmc1: pd.DataFrame, duration_s: float) -> np.ndarray:
    """mmc1's own (uneven) sample times that fall within ``duration_s``.

    Parameters
    ----------
    mmc1 : pandas.DataFrame
        Output of :func:`load_mmc1`.
    duration_s : float
        Run length, s.

    Returns
    -------
    numpy.ndarray
        Sample times, s, ascending.
    """
    t = mmc1.t_s.to_numpy()
    return t[t <= duration_s + 1e-9]


def quiet_window(mmc1: pd.DataFrame, length: int = QUIET_LENGTH) -> dict:
    """The quietest stretch of mmc1's accelerometer, as a noise upper bound (step 5).

    Each window of ``length`` consecutive samples has a least-squares line in time removed
    from every axis; the window with the lowest summed residual variance wins. One window
    serves all three axes.

    Parameters
    ----------
    mmc1 : pandas.DataFrame
        Output of :func:`load_mmc1`.
    length : int
        Window length in samples.

    Returns
    -------
    dict
        ``start`` index, ``t0``/``t1`` in s, per-axis ``sigma`` (m/s^2, ddof = 2 for the two
        fitted line parameters) and per-axis lag-1 autocorrelation ``lag1`` of the residual.
    """
    t = mmc1.t_s.to_numpy()
    acc = mmc1[["ax_g", "ay_g", "az_g"]].to_numpy() * G  # g, gravity included -> m/s^2
    best = None
    for i in range(len(t) - length + 1):
        tt, aa = t[i : i + length], acc[i : i + length]
        resid = np.column_stack([aa[:, c] - np.polyval(np.polyfit(tt, aa[:, c], 1), tt) for c in range(3)])
        score = float((resid**2).sum())
        if best is None or score < best[0]:
            best = (score, i, resid)
    _, i, resid = best
    return dict(
        start=i,
        t0=float(t[i]),
        t1=float(t[i + length - 1]),
        sigma=np.sqrt((resid**2).sum(axis=0) / (length - 2)),
        lag1=(resid[:-1] * resid[1:]).sum(axis=0) / (resid**2).sum(axis=0),
    )


def majority_sign_fraction(d: np.ndarray) -> float:
    """Fraction of samples sharing the curve's majority sign; exact zeros count as neither.

    Parameters
    ----------
    d : numpy.ndarray
        One delta-a curve.

    Returns
    -------
    float
        ``max(n_pos, n_neg) / n``.
    """
    return max(int((d > 0).sum()), int((d < 0).sum())) / d.size


def correlation(a: np.ndarray, b: np.ndarray) -> float:
    """Pearson correlation of two curves; NaN when either is constant.

    Parameters
    ----------
    a, b : numpy.ndarray
        Curves of equal length.

    Returns
    -------
    float
        Correlation coefficient in [-1, 1], or NaN.
    """
    if np.ptp(a) == 0 or np.ptp(b) == 0:
        return float("nan")
    return float(np.corrcoef(a, b)[0, 1])


def standard_error(kind: str, value: float, n: int) -> float:
    """Standard error of a Monte Carlo statistic over n draws, by the usual normal-theory approximations.

    Printed beside each statistic (the author's choice, AI-USE.md section 4, 2026-10-28), because "settled < 5 %"
    is a stopping rule, not a statement of precision.

    Parameters
    ----------
    kind : {'mean', 'sd', 'fraction', 'corr'}
        Which statistic: a mean (pass the draws' sd as value), a standard deviation (pass the sd), a fraction (pass
        p) or a correlation (pass r).
    value : float
        As above. NaN gives NaN.
    n : int
        Draws behind the statistic: the converged fits for k and V0, every fit for a fraction.

    Returns
    -------
    float
        sd/sqrt(n) for a mean; sd/sqrt(2(n - 1)) for an sd; sqrt(p(1 - p)/n) for a fraction;
        (1 - r^2)/sqrt(n - 1) for a correlation. NaN when n is too small.

    Raises
    ------
    ValueError
        If kind is not one of the four.
    """
    if kind == "mean":
        return float(value / np.sqrt(n)) if n > 0 else float("nan")
    if kind == "sd":
        return float(value / np.sqrt(2 * (n - 1))) if n > 1 else float("nan")
    if kind == "fraction":
        return float(np.sqrt(value * (1 - value) / n)) if n > 0 else float("nan")
    if kind == "corr":
        return float((1 - value**2) / np.sqrt(n - 1)) if n > 1 else float("nan")
    raise ValueError(f"kind must be 'mean', 'sd', 'fraction' or 'corr', got {kind!r}")


RC = {
    "figure.facecolor": SURFACE, "axes.facecolor": SURFACE, "savefig.facecolor": SURFACE,
    "axes.edgecolor": INK_2, "axes.labelcolor": INK, "text.color": INK,
    "xtick.color": INK_2, "ytick.color": INK_2, "axes.grid": True, "grid.color": GRID,
    "grid.linewidth": 0.6, "axes.axisbelow": True, "legend.frameon": False,
    "axes.spines.top": False, "axes.spines.right": False,
}


def drop_inconsistent(df: pd.DataFrame, tol: float = DECOMP_TOL) -> tuple[pd.DataFrame, int]:
    """Keep rows whose friction + planing + rail drag adds up to the total drag (step 1).

    Parameters
    ----------
    df : pandas.DataFrame
        Live-solver rows with ``drag_total_n``, ``friction_n``, ``fx_planing_n``, ``fx_rail_n``.
    tol : float
        Allowed mismatch as a fraction of ``|drag_total_n|``.

    Returns
    -------
    kept : pandas.DataFrame
        The consistent rows.
    n_dropped : int
        How many rows failed.
    """
    gap = (df.drag_total_n - (df.friction_n + df.fx_planing_n + df.fx_rail_n)).abs()
    ok = gap <= tol * df.drag_total_n.abs()
    return df[ok], int((~ok).sum())


def load_forces(path: Path = SOLVER_CSV) -> tuple[pd.DataFrame, int]:
    """Converged live-solver reads at slope 0 and drift 0 that pass the decomposition check.

    Parameters
    ----------
    path : pathlib.Path
        ``converged/solver_points.csv``.

    Returns
    -------
    kept : pandas.DataFrame
        Rows kept.
    n_dropped : int
        Rows dropped by :func:`drop_inconsistent`.
    """
    d = pd.read_csv(path)
    return drop_inconsistent(d[(d.slope_deg == 0) & (d.drift_deg == 0)])


def continuous_range(speeds: np.ndarray) -> tuple[float, float]:
    """Longest run of consecutive 1 m/s grid speeds; among equal runs, the fastest.

    Parameters
    ----------
    speeds : numpy.ndarray
        Converged speeds of one attitude, m/s.

    Returns
    -------
    tuple of float
        ``(v_lo, v_hi)`` of that run, m/s.
    """
    v = np.sort(np.unique(speeds))
    best, start = (v[0], v[0]), v[0]
    for i in range(1, v.size + 1):
        if i == v.size or not np.isclose(v[i] - v[i - 1], 1.0):
            if v[i - 1] - start >= best[1] - best[0]:
                best = (float(start), float(v[i - 1]))
            if i < v.size:
                start = v[i]
    return best


def equilibria(drag, lo: float, hi: float, drive: float) -> list[float]:
    """Speeds in ``[lo, hi]`` where drag equals the slope's weight component.

    Parameters
    ----------
    drag : callable
        ``drag(V) -> N``, vectorised.
    lo, hi : float
        Speed range, m/s.
    drive : float
        ``m g sin(slope)``, N.

    Returns
    -------
    list of float
        Every crossing, ascending (a drag hump gives two).
    """
    v = np.linspace(lo, hi, 801)
    x = np.asarray(drag(v), dtype=float) - drive
    return [float(brentq(lambda s: float(drag(s)) - drive, v[i], v[i + 1]))
            for i in np.where(np.sign(x[:-1]) * np.sign(x[1:]) < 0)[0]]


@dataclass(frozen=True)
class Forces:
    """One attitude's drag components against speed, as shape-preserving (PCHIP) interpolants.

    Attributes
    ----------
    pos_y, pos_x : float
        The attitude (SWD scan position).
    friction, planing, rail, total : scipy.interpolate.PchipInterpolator
        ``friction_n``, ``fx_planing_n``, ``fx_rail_n`` and SWD's own ``drag_total_n``, N. None
        extrapolates: outside the grid they return NaN.
    """

    pos_y: float
    pos_x: float
    friction: PchipInterpolator
    planing: PchipInterpolator
    rail: PchipInterpolator
    total: PchipInterpolator

    @classmethod
    def at(cls, df: pd.DataFrame, pos_y: float, pos_x: float, v_lo: float, v_hi: float) -> "Forces":
        """Build the interpolants for one attitude over its continuous converged range.

        Parameters
        ----------
        df : pandas.DataFrame
            Output of :func:`load_forces`.
        pos_y, pos_x : float
            The attitude.
        v_lo, v_hi : float
            Its continuous converged speed range, m/s.

        Returns
        -------
        Forces
        """
        g = df[(df.pos_y == pos_y) & (df.pos_x == pos_x) & df.speed_ms.between(v_lo, v_hi)].sort_values("speed_ms")
        v = g.speed_ms.to_numpy(dtype=float)
        p = {c: PchipInterpolator(v, g[c].to_numpy(dtype=float), extrapolate=False)
             for c in ("friction_n", "fx_planing_n", "fx_rail_n", "drag_total_n")}
        return cls(pos_y, pos_x, p["friction_n"], p["fx_planing_n"], p["fx_rail_n"], p["drag_total_n"])

    @property
    def v_range(self) -> tuple[float, float]:
        """The converged speed range the interpolants cover, m/s."""
        return float(self.friction.x[0]), float(self.friction.x[-1])

    def drag_poly(self, k: float) -> PPoly:
        """``k * friction + planing + rail`` as one piecewise cubic.

        Parameters
        ----------
        k : float
            Friction multiplier.

        Returns
        -------
        scipy.interpolate.PPoly
            The same polynomial as the sum of the three PCHIPs (they share breakpoints), evaluated
            once per call instead of three times; NaN outside the range.
        """
        return PPoly(k * self.friction.c + self.planing.c + self.rail.c, self.friction.x, extrapolate=False)


def integrate(drag, v0: float, t_end: float, v_range: tuple[float, float], m: float = MASS_KG,
              slope_deg: float = SLOPE_DEG, rtol: float = RTOL):
    """Integrate ``m dV/dt = m g sin(slope) - D(V)`` with RK45, stopping where V leaves the range.

    Parameters
    ----------
    drag : callable
        ``drag(V) -> N`` (scalar in, scalar out).
    v0 : float
        Starting speed, m/s.
    t_end : float
        Run length, s.
    v_range : tuple of float
        ``(lo, hi)`` the forces are valid over, m/s.
    m : float
        Mass, kg.
    slope_deg : float
        Constant surface slope; its weight component is a separate term because the 0-degree
        forces do not contain it.
    rtol : float
        Relative tolerance.

    Returns
    -------
    scipy.integrate.OdeResult
        With dense output; ``t[-1]`` is ``t_end``, or the time V reached a range edge.
    """
    lo, hi = v_range
    drive = m * G * np.sin(np.radians(slope_deg))

    def rhs(t, y):
        """dV/dt. Trial stages of a step that crosses an edge can land just past it; the force there
        is held at its edge value, and the terminal events below cut the run at the edge."""
        return [(drive - float(drag(min(max(y[0], lo), hi)))) / m]

    def below(t, y):
        """Zero where V reaches the bottom of the range."""
        return y[0] - lo

    def above(t, y):
        """Zero where V reaches the top of the range."""
        return y[0] - hi

    below.terminal = above.terminal = True
    return solve_ivp(rhs, (0.0, t_end), [v0], method="RK45", rtol=rtol, atol=ATOL,
                     events=[below, above], dense_output=True)


def run_accel(forces: Forces, k: float, v0: float, t_end: float, t: np.ndarray, rtol: float = RTOL):
    """Along-path acceleration at the sample times the run reaches, from the right-hand side.

    Parameters
    ----------
    forces : Forces
        The attitude.
    k, v0 : float
        Friction multiplier and starting speed.
    t_end : float
        Run length, s.
    t : numpy.ndarray
        Sample times, s, ascending.
    rtol : float
        Relative tolerance for :func:`integrate`.

    Returns
    -------
    a : numpy.ndarray
        ``(m g sin(slope) - D(V(t)))/m`` at the covered samples, m/s^2 (no differentiation of V).
    t_reached : float
        End of the run, s.
    sol : scipy.integrate.OdeResult
        The integration, for V(t).
    """
    lo, hi = forces.v_range
    d = forces.drag_poly(k)
    sol = integrate(d, v0, t_end, (lo, hi), rtol=rtol)
    t_reached = float(sol.t[-1])
    v = sol.sol(t[t <= t_reached + 1e-12])[0]
    # Only round-off may sit outside the range at the cut; anything more would be extrapolation.
    clipped = np.clip(v, lo, hi)
    if v.size and np.max(np.abs(v - clipped)) > EDGE_TOL:
        raise RuntimeError(f"V left the converged range by {np.max(np.abs(v - clipped)):.3g} m/s at a sample")
    return (WEIGHT_N * np.sin(np.radians(SLOPE_DEG)) - d(clipped)) / MASS_KG, t_reached, sol


def rank_attitudes(df: pd.DataFrame, top: int = 5) -> pd.DataFrame:
    """Rank attitudes by step 2's rule and describe the leaders.

    Rule: widest continuous converged speed range, then the smallest ``|pos_y|``, then ``pos_x``
    nearest the median ``pos_x`` of the kept rows.

    Parameters
    ----------
    df : pandas.DataFrame
        Output of :func:`load_forces`.
    top : int
        How many leaders get forces and equilibria attached.

    Returns
    -------
    pandas.DataFrame
        Every attitude in rank order; the first ``top`` rows also carry the end forces and the
        equilibrium speeds.
    """
    med_x = float(df.pos_x.median())
    rows = []
    for (py, px), g in df.groupby(["pos_y", "pos_x"]):
        lo, hi = continuous_range(g.speed_ms.to_numpy(dtype=float))
        rows.append(dict(pos_y=py, pos_x=px, v_lo=lo, v_hi=hi, width=hi - lo))
    c = pd.DataFrame(rows)
    c = c.assign(_y=c.pos_y.abs(), _x=(c.pos_x - med_x).abs())
    c = c.sort_values(["width", "_y", "_x"], ascending=[False, True, True]).drop(columns=["_y", "_x"])
    c = c.reset_index(drop=True)
    drive = WEIGHT_N * np.sin(np.radians(SLOPE_DEG))
    extra = []
    for _, r in c.head(top).iterrows():
        if r.width < 1:  # one converged speed: nothing to interpolate
            extra.append({})
            continue
        f = Forces.at(df, r.pos_y, r.pos_x, r.v_lo, r.v_hi)
        e = {}
        for end, v in (("lo", r.v_lo), ("hi", r.v_hi)):
            e[f"friction_n_at_{end}"] = float(f.friction(v))
            e[f"fx_planing_n_at_{end}"] = float(f.planing(v))
            e[f"fx_rail_n_at_{end}"] = float(f.rail(v))
        e["v_eq_swd_total_k1"] = "; ".join(f"{x:.3f}" for x in equilibria(f.total, r.v_lo, r.v_hi, drive)) or "none in range"
        e["v_eq_model_k_planted"] = "; ".join(f"{x:.3f}" for x in equilibria(f.drag_poly(PLANTED), r.v_lo, r.v_hi, drive)) or "none in range"
        extra.append(e)
    return pd.concat([c, pd.DataFrame(extra)], axis=1)


def choose_v0(forces: Forces, t_end: float) -> tuple[float | None, pd.DataFrame]:
    """Step 3: the starting speed whose baseline run stays in range longest.

    V0 runs over the range in 0.1 m/s steps, keeping only values whose +/- V0_SHIFT copies are in
    range too. Ties go to the largest change in V over the run, which is what separates friction
    from planing.

    Parameters
    ----------
    forces : Forces
        The attitude.
    t_end : float
        Run length used for the choice (mmc1's span), s.

    Returns
    -------
    v0 : float or None
        The choice, or None if no V0 qualifies.
    table : pandas.DataFrame
        Every grid value with ``qualifies``, ``t_in_range``, ``v_end`` and ``dv``.
    """
    lo, hi = forces.v_range
    d = forces.drag_poly(PLANTED)
    rows = []
    for tenth in range(int(round(lo * 10)), int(round(hi * 10)) + 1):
        v0 = tenth / 10
        ok = v0 * (1 - V0_SHIFT) >= lo - 1e-9 and v0 * (1 + V0_SHIFT) <= hi + 1e-9
        row = dict(v0=v0, qualifies=ok, t_in_range=np.nan, v_end=np.nan, dv=np.nan)
        if ok:
            sol = integrate(d, v0, t_end, (lo, hi))
            row.update(t_in_range=float(sol.t[-1]), v_end=float(sol.y[0, -1]), dv=abs(float(sol.y[0, -1]) - v0))
        rows.append(row)
    table = pd.DataFrame(rows)
    q = table[table.qualifies]
    if q.empty:
        return None, table
    best = q.sort_values(["t_in_range", "dv"], ascending=[False, False]).iloc[0]
    return float(best.v0), table


def select(df: pd.DataFrame, t_end: float) -> dict:
    """Attitude and starting speed by the rules of steps 2 and 3, falling back down the ranking.

    Parameters
    ----------
    df : pandas.DataFrame
        Output of :func:`load_forces`.
    t_end : float
        mmc1's span, s.

    Returns
    -------
    dict
        ``candidates`` (the ranking), ``forces`` and ``v0`` (None if nothing qualifies), ``rank``
        of the attitude used, and ``v0_table`` for it.
    """
    candidates = rank_attitudes(df)
    out = dict(candidates=candidates, forces=None, v0=None, rank=None, v0_table=None)
    for rank, r in candidates.iterrows():
        if r.width < 1:  # one converged speed: nothing to interpolate
            continue
        f = Forces.at(df, r.pos_y, r.pos_x, r.v_lo, r.v_hi)
        v0, table = choose_v0(f, t_end)
        if v0 is not None:
            return dict(out, forces=f, v0=v0, rank=int(rank), v0_table=table)
    return out


def residuals(params, forces: Forces, data: np.ndarray, sigma: float, t: np.ndarray, t_end: float,
              v0_fixed: float | None, hits: list[int]) -> np.ndarray:
    """Noise-weighted misfit of a_x; samples a trial run never reached get a fixed penalty.

    Parameters
    ----------
    params : numpy.ndarray
        ``[k]`` when ``v0_fixed`` is given (set a), else ``[k, v0]`` (set b).
    forces : Forces
        The attitude.
    data : numpy.ndarray
        a_x being fitted, at ``t``.
    sigma : float
        Noise standard deviation, m/s^2.
    t : numpy.ndarray
        Sample times, s.
    t_end : float
        Run length, s.
    v0_fixed : float or None
        Starting speed held fixed, or None to fit it.
    hits : list of int
        One-element counter, incremented when a trial leaves the range early.

    Returns
    -------
    numpy.ndarray
        One residual per sample.
    """
    k, v0 = (params[0], v0_fixed) if v0_fixed is not None else (params[0], params[1])
    a, _, _ = run_accel(forces, k, v0, t_end, t)
    r = np.full(t.size, GUARD_RESIDUAL)
    r[: a.size] = (a - data[: a.size]) / sigma
    if a.size < t.size:
        hits[0] += 1
    return r


def fit(forces: Forces, data: np.ndarray, sigma: float, t: np.ndarray, t_end: float, v0_true: float,
        joint: bool) -> dict:
    """Fit k (set a) or k and V0 (set b) from deliberately shifted starts.

    Parameters
    ----------
    forces : Forces
        The attitude.
    data : numpy.ndarray
        a_x at ``t``, m/s^2.
    sigma : float
        Noise standard deviation, m/s^2.
    t : numpy.ndarray
        Sample times, s.
    t_end : float
        Run length, s.
    v0_true : float
        True starting speed: fixed in set a, perturbed for the start in set b.
    joint : bool
        True for set b.

    Returns
    -------
    dict
        ``k_fit``, ``v0_fit`` (NaN for set a), ``converged``, ``at_bound``, ``guard_hits``, ``nfev``.
    """
    lo, hi = forces.v_range
    hits = [0]
    if joint:
        x0, bounds = [PLANTED * (1 + FRICTION_SHIFT), v0_true * (1 + V0_SHIFT)], ([0.0, lo], [np.inf, hi])
    else:
        x0, bounds = [PLANTED * (1 + FRICTION_SHIFT)], ([0.0], [np.inf])
    res = least_squares(residuals, x0, bounds=bounds, diff_step=DIFF_STEP,
                        args=(forces, data, sigma, t, t_end, None if joint else v0_true, hits))
    k = float(res.x[0])
    v0 = float(res.x[1]) if joint else v0_true
    # A fit is only usable if its own run reaches every sample it was fitted to.
    covers = run_accel(forces, k, v0, t_end, t)[0].size == t.size
    return dict(k_fit=k, v0_fit=v0 if joint else np.nan, converged=bool(res.success) and covers,
                at_bound=bool(np.any(res.active_mask != 0)), guard_hits=hits[0], nfev=int(res.nfev))


class NoiseDraws:
    """Standard-normal draws, made one at a time in a fixed order so draw i never changes.

    Parameters
    ----------
    seed : int
        Seed of the generator.
    n : int
        Samples per draw.
    """

    def __init__(self, seed: int, n: int):
        """Start the generator; no draw is made until one is asked for."""
        self._rng, self._n, self._draws = np.random.default_rng(seed), n, []

    def __getitem__(self, i: int) -> np.ndarray:
        """Draw ``i``, generating any earlier ones first."""
        while len(self._draws) <= i:
            self._draws.append(self._rng.standard_normal(self._n))
        return self._draws[i]


def monte_carlo(forces: Forces, clean: np.ndarray, noise: NoiseDraws, sigma: float, t: np.ndarray, t_end: float,
                v0_true: float, joint: bool, allowance_s: float, per_fit_est: float) -> tuple[list[dict], dict]:
    """Fit noisy copies of the baseline, doubling N until the sd of k settles or the time runs out.

    Parameters
    ----------
    forces : Forces
        The attitude.
    clean : numpy.ndarray
        Baseline a_x at ``t``.
    noise : NoiseDraws
        Shared standard-normal draws; draw i is scaled by ``sigma``.
    sigma : float
        Noise standard deviation, m/s^2.
    t : numpy.ndarray
        Sample times, s.
    t_end : float
        Run length, s.
    v0_true : float
        True starting speed, m/s.
    joint : bool
        True for set b.
    allowance_s : float
        Wall time this combination may use, s.
    per_fit_est : float
        Timed seconds per fit, used until real fits replace it.

    Returns
    -------
    fits : list of dict
        Every fit, in draw order.
    stop : dict
        ``n`` and ``n2`` of the last comparison with their ``sd_n`` and ``sd_n2``, ``settled``,
        and ``capped`` when the time cap ended the doubling.
    """
    fits: list[dict] = []
    start = time.perf_counter()

    def per_fit() -> float:
        """Seconds per fit so far (the timing estimate before the first fit)."""
        return (time.perf_counter() - start) / len(fits) if fits else per_fit_est

    def sd_k(n: int) -> float:
        """sd (ddof 1) of converged fitted k among the first n draws."""
        k = [f["k_fit"] for f in fits[:n] if f["converged"]]
        return float(np.std(k, ddof=1)) if len(k) > 1 else float("nan")

    def extend(n: int) -> None:
        """Fit draws until there are n fits."""
        while len(fits) < n:
            fits.append(fit(forces, clean + noise[len(fits)] * sigma, sigma, t, t_end, v0_true, joint))

    stop = dict(n=np.nan, n2=np.nan, sd_n=np.nan, sd_n2=np.nan, settled=False, capped=False)
    first = min(N0, max(2, int(allowance_s / per_fit_est)))
    extend(first)
    if first < N0:
        return fits, dict(stop, n=first, capped=True)
    n = N0
    while True:
        if time.perf_counter() - start + n * per_fit() > allowance_s:
            return fits, dict(stop, capped=True)
        extend(2 * n)
        sd_n, sd_n2 = sd_k(n), sd_k(2 * n)
        stop.update(n=n, n2=2 * n, sd_n=sd_n, sd_n2=sd_n2)
        if sd_n > 0 and abs(sd_n2 - sd_n) / sd_n < STD_REL_TOL:
            return fits, dict(stop, settled=True)
        n *= 2


def mc_stats(f: pd.DataFrame, joint: bool) -> dict:
    """Summary of one set of fits, with the conventions stated in READINGS.

    Parameters
    ----------
    f : pandas.DataFrame
        Fits with ``k_fit``, ``v0_fit``, ``converged`` (and ``at_bound`` where known).
    joint : bool
        True for set b (adds the V0 statistics).

    Returns
    -------
    dict
        N, mean and sd of k, sd / (FRICTION_SHIFT x PLANTED), within-band fraction, converged
        and at-bound fractions, and for set b the V0 mean, sd and corr(k, V0). Each statistic is
        followed by its standard error, "SE ..." (:func:`standard_error`).
    """
    ok = f[f.converged]
    band = FRICTION_SHIFT * PLANTED
    sd = ok.k_fit.std(ddof=1)
    within = (((f.k_fit - PLANTED).abs() <= band) & f.converged).mean() if len(f) else np.nan
    at_bound = f.at_bound.mean() if "at_bound" in f else np.nan
    sd_v0 = ok.v0_fit.std(ddof=1) if joint else np.nan
    corr = correlation(ok.k_fit.to_numpy(), ok.v0_fit.to_numpy()) if joint else np.nan
    se = standard_error
    # Each statistic with its standard error beside it (the author's choice, AI-USE.md section 4, 2026-10-28):
    # "settled" is a stopping rule, not a precision
    return {
        "N": len(f), "mean k": ok.k_fit.mean(), "SE mean k": se("mean", sd, len(ok)),
        "sd k": sd, "SE sd k": se("sd", sd, len(ok)),
        "sd k / (shift x PLANTED)": sd / band, "SE sd k / (shift x PLANTED)": se("sd", sd, len(ok)) / band,
        "within ±band": within, "SE within ±band": se("fraction", within, len(f)),
        "converged": f.converged.mean(), "SE converged": se("fraction", f.converged.mean(), len(f)),
        "at bound": at_bound, "SE at bound": se("fraction", at_bound, len(f)),
        "mean V0": ok.v0_fit.mean() if joint else np.nan, "SE mean V0": se("mean", sd_v0, len(ok)),
        "sd V0": sd_v0, "SE sd V0": se("sd", sd_v0, len(ok)),
        "corr(k, V0)": corr, "SE corr(k, V0)": se("corr", corr, len(ok)),
    }


def plot_speed(runs: dict, forces: Forces, path: Path) -> None:
    """V(t) of every run, with the converged range and the model's equilibria at k = PLANTED.

    Parameters
    ----------
    runs : dict
        duration -> run name -> output of :func:`run_accel`.
    forces : Forces
        The attitude.
    path : pathlib.Path
        PNG to write.
    """
    import matplotlib.pyplot as plt

    lo, hi = forces.v_range
    eq = equilibria(forces.drag_poly(PLANTED), lo, hi, WEIGHT_N * np.sin(np.radians(SLOPE_DEG)))
    fig, axes = plt.subplots(1, len(runs), figsize=(12, 4.8), constrained_layout=True, squeeze=False)
    for ax, (dur, rr) in zip(axes[0], runs.items()):
        for name in ("base",) + SHIFTED:
            _, t_reached, sol = rr[name]
            tt = np.linspace(0.0, t_reached, 400)
            ax.plot(tt, sol.sol(tt)[0], **LINE[name], label=RUN_LABEL[name])
        for v in (lo, hi):
            ax.axhline(v, color=INK_2, lw=0.8, ls=":")
        for v in eq:
            ax.axhline(v, color=INK_2, lw=0.8, ls="-.")
        ax.set_title(f"{dur:g} s run (dotted: converged range; dash-dot: D = m g sin 10° at k = {PLANTED})", fontsize=9)
        ax.set_xlabel("time (s)")
        ax.set_ylabel("V (m/s)")
        # The runs stay above the unstable equilibrium; lift the box off the 2 m/s range line.
        ax.legend(fontsize=8, loc="lower left", bbox_to_anchor=(0.0, 0.07))
    fig.suptitle(f"Speed of each run, attitude pos_y {forces.pos_y:g}, pos_x {forces.pos_x:g} (feasibility screen only)")
    fig.savefig(path, dpi=150)
    plt.close(fig)


def plot_delta(curves: dict, sigma: dict, path: Path) -> None:
    """Delta-a_x at the sample times against both +/- sigma bands, friction and V0 apart.

    Parameters
    ----------
    curves : dict
        duration -> ``(t, {run: delta-a_x})``.
    sigma : dict
        ``"upper"``/``"lower"`` -> sigma_x, m/s^2.
    path : pathlib.Path
        PNG to write.
    """
    import matplotlib.pyplot as plt

    fig, axes = plt.subplots(len(curves), 2, figsize=(12, 4.2 * len(curves)), constrained_layout=True, squeeze=False)
    for row, (dur, (t, d)) in enumerate(curves.items()):
        for col, (title, pair) in enumerate((("Friction shift", FRICTION_RUNS), ("Starting-speed shift", V0_RUNS))):
            ax = axes[row, col]
            peak = max(np.abs(d[n]).max() for n in pair)
            lim = 1.15 * max(peak, sigma["lower"])
            for case, colour in (("upper", BAND_UPPER), ("lower", BAND_LOWER)):
                ax.axhspan(-sigma[case], sigma[case], color=colour, lw=0, label=f"±σ {case} bound ({sigma[case]:.3g} m/s²)")
            if sigma["upper"] > lim:
                ax.text(0.99, 0.04, "upper-bound band extends past this axis", ha="right", transform=ax.transAxes,
                        fontsize=8, color=INK_2)
            for name in pair:
                ax.plot(t, d[name], **LINE[name], marker="o" if name.endswith("+") else "s", ms=4, label=RUN_LABEL[name])
            ax.set_ylim(-lim, lim)
            ax.set_title(f"{title}, {dur:g} s run", fontsize=10)
            ax.set_ylabel("Δa_x (m/s²)")
            ax.set_xlabel("time from first sample (s)")
            ax.legend(fontsize=8, loc="upper right")
    fig.suptitle("Shifted run minus baseline, along-path acceleration at mmc1 sample times")
    fig.savefig(path, dpi=150)
    plt.close(fig)


def plot_overlay(curves: dict, path: Path) -> None:
    """Friction and V0 delta-a_x, each normalised by its own maximum, overlaid per duration.

    Parameters
    ----------
    curves : dict
        duration -> ``(t, {run: delta-a_x})``.
    path : pathlib.Path
        PNG to write.
    """
    import matplotlib.pyplot as plt

    fig, axes = plt.subplots(len(curves), 1, figsize=(9, 3.8 * len(curves)), constrained_layout=True, squeeze=False)
    for ax, (dur, (t, d)) in zip(axes[:, 0], curves.items()):
        for name in ("k+", "v0+"):
            peak = np.abs(d[name]).max()
            ax.plot(t, d[name] / peak if peak > 0 else d[name], **LINE[name],
                    marker="o" if name == "k+" else "s", ms=4, label=f"{RUN_LABEL[name]}  (max |Δa_x| = {peak:.3g} m/s²)")
        ax.axhline(0.0, color=INK_2, lw=0.8)
        ax.set_title(f"{dur:g} s run: corr(k+, V0+) = {correlation(d['k+'], d['v0+']):+.3f}", fontsize=10)
        ax.set_ylabel("Δa_x / max|Δa_x|")
        ax.set_xlabel("time from first sample (s)")
        ax.legend(fontsize=8, loc="best")
    fig.suptitle("Shape of the friction and starting-speed signatures in a_x")
    fig.savefig(path, dpi=150)
    plt.close(fig)


def plot_fitted_k(fits: pd.DataFrame, stops: dict, path: Path) -> None:
    """Histograms of the converged fitted k, sets a and b, per duration and sigma case.

    Parameters
    ----------
    fits : pandas.DataFrame
        Every fit, as in ``monte_carlo_fits.csv``.
    stops : dict
        ``(duration, case, set)`` -> stop record, to mark capped runs.
    path : pathlib.Path
        PNG to write.
    """
    import matplotlib.pyplot as plt

    durations = sorted(fits.duration_s.unique())
    band = FRICTION_SHIFT * PLANTED
    fig, axes = plt.subplots(len(durations), 2, figsize=(12, 4.3 * len(durations)), constrained_layout=True, squeeze=False)
    for i, dur in enumerate(durations):
        for j, case in enumerate(SIGMA_CASES):
            ax = axes[i, j]
            sub = fits[(fits.duration_s == dur) & (fits.sigma_case == case) & fits.converged]
            ax.axvspan(PLANTED - band, PLANTED + band, color=BAND_UPPER, lw=0,
                       label=f"PLANTED ± FRICTION_SHIFT × PLANTED (±{band:.2f})")
            ax.axvline(PLANTED, color=INK, lw=1.5, label=f"planted k = {PLANTED}")
            top = 0
            if len(sub):
                edges = np.linspace(sub.k_fit.min(), sub.k_fit.max(), 41) if sub.k_fit.max() > sub.k_fit.min() else 40
                for s, colour, ls in (("a", SERIES_1, "-"), ("b", SERIES_2, "--")):
                    k = sub[sub.set == s].k_fit
                    capped = " [capped]" if stops[(dur, case, s)]["capped"] else ""
                    counts, _, _ = ax.hist(k, bins=edges, histtype="step", lw=1.5, ls=ls, color=colour,
                                           label=f"set ({s}): mean {k.mean():.4f}, sd {k.std(ddof=1):.3g}, n = {k.size}{capped}")
                    top = max(top, counts.max() if len(counts) else 0)
            ax.set_ylim(0, 1.8 * max(top, 1))  # headroom so the legend clears the bars
            ax.set_title(f"{dur:g} s run, sigma {case} bound", fontsize=10)
            ax.set_xlabel("fitted k")
            ax.set_ylabel("draws")
            ax.legend(fontsize=8, loc="upper left")
    fig.suptitle("Fitted friction multiplier over noise draws, a_x only (converged fits; feasibility screen)")
    fig.savefig(path, dpi=150)
    plt.close(fig)


RUN_LABEL = {
    "base": f"baseline (k = {PLANTED})",
    "k+": f"k = {PLANTED * (1 + FRICTION_SHIFT):.3f} (friction +{FRICTION_SHIFT:.0%})",
    "k-": f"k = {PLANTED * (1 - FRICTION_SHIFT):.3f} (friction −{FRICTION_SHIFT:.0%})",
    "v0+": f"V0 × {1 + V0_SHIFT:g}",
    "v0-": f"V0 × {1 - V0_SHIFT:g}",
}
# Colour says which parameter moved, line style says which way (validated pair: dataviz light slots 1-2).
LINE = {
    "base": dict(color=INK, lw=1.5),
    "k+": dict(color=SERIES_1, lw=1.5, ls="-"),
    "k-": dict(color=SERIES_1, lw=1.5, ls="--"),
    "v0+": dict(color=SERIES_2, lw=1.5, ls="-"),
    "v0-": dict(color=SERIES_2, lw=1.5, ls="--"),
}


def sigma_x(mmc1: pd.DataFrame) -> dict:
    """The x-axis noise sigmas of the first screen, computed from mmc1.

    Parameters
    ----------
    mmc1 : pandas.DataFrame
        Output of :func:`load_mmc1`.

    Returns
    -------
    dict
        ``"upper"`` -> the author's quiet window's sigma_x, ``"lower"`` -> ``RESOLUTION_SIGMA``, m/s^2.

    Raises
    ------
    RuntimeError
        If the quiet-window search no longer lands on the author's confirmed start.
    """
    qw = quiet_window(mmc1)
    if qw["start"] != QUIET_START:
        raise RuntimeError(f"quiet-window search now lands on index {qw['start']}, not the "
                           f"confirmed {QUIET_START}; re-confirm the window with the author")
    return {"upper": float(qw["sigma"][0]), "lower": float(RESOLUTION_SIGMA)}


def main() -> None:
    """Run the screen end to end and write its outputs."""
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")  # σ, Δ and ± on a cp1252 console
    import matplotlib

    matplotlib.use("Agg")
    matplotlib.rcParams.update(RC)
    pd.set_option("display.width", 220)
    pd.set_option("display.max_columns", 40)
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    fmt = lambda x: f"{x:.5g}"  # noqa: E731  (5 figures, so 10.055 s prints as itself)

    print("=== Second identifiability screen: single-attitude live-solver forces (FEASIBILITY ONLY) ===")
    print("Not the project's forward model; not to be reused or described as one.")
    print(f"PLANTED = {PLANTED}, FRICTION_SHIFT = {FRICTION_SHIFT}, V0_SHIFT = {V0_SHIFT}, SLOPE_DEG = {SLOPE_DEG}; "
          f"m = {WEIGHT_N} N / {G} = {MASS_KG:.4f} kg; m g sin(slope) = {WEIGHT_N * np.sin(np.radians(SLOPE_DEG)):.3f} N")

    mmc1 = load_mmc1()
    sigma = sigma_x(mmc1)
    print(f"sigma_x, the first screen's bounds: upper {sigma['upper']:.5f} m/s² (20-sample window, t = 1.498-2.795 s), "
          f"lower {sigma['lower']:.5f} m/s² (0.01 g resolution floor)")

    durations = (3.0, float(mmc1.t_s.iloc[-1]))

    # Steps 1-3: forces, attitude, V0.
    df, n_dropped = load_forces()
    print(f"\nStep 1 - slope 0, drift 0: {len(df) + n_dropped} converged rows; {n_dropped} dropped "
          f"(components off the total by > {DECOMP_TOL:.0%}); {len(df)} kept over {df.groupby(['pos_y', 'pos_x']).ngroups} attitudes")
    sel = select(df, durations[1])
    cand = sel["candidates"]
    cand.head(5).to_csv(OUT_DIR / "attitude_candidates.csv", index=False, encoding="utf-8")
    print(f"\nStep 2 - attitude rule (widest continuous converged range; then smallest |pos_y|; then pos_x nearest "
          f"the median {df.pos_x.median():g}). Top 5:")
    print(cand.head(5).to_string(index=False, float_format=fmt))

    summary = [dict(metric="rows_dropped_step1", value=n_dropped), dict(metric="rows_kept_step1", value=len(df))]
    if sel["forces"] is None:
        print("\n*** MAIN FINDING: no attitude has a starting speed V0 with V0 x (1 +/- V0_SHIFT) inside its converged "
              "range, so no run could be made. Candidates and forces are written; nothing else is. ***")
        pd.DataFrame(summary).to_csv(OUT_DIR / "summary.csv", index=False, encoding="utf-8")
        return
    forces, v0 = sel["forces"], sel["v0"]
    lo, hi = forces.v_range
    sel["v0_table"].to_csv(OUT_DIR / "v0_search.csv", index=False, encoding="utf-8")
    df[(df.pos_y == forces.pos_y) & (df.pos_x == forces.pos_x) & df.speed_ms.between(lo, hi)].sort_values("speed_ms")[
        ["pos_y", "pos_x", "speed_ms", "friction_n", "fx_planing_n", "fx_rail_n", "drag_total_n", "lift_n",
         "planing_angle_deg", "wetted_area_m2", "lift_dev"]].to_csv(OUT_DIR / "forces_used.csv", index=False, encoding="utf-8")
    q = sel["v0_table"][sel["v0_table"].qualifies]
    print(f"\nChosen attitude (rank {sel['rank'] + 1}; PROVISIONAL, pending review): pos_y {forces.pos_y:g}, "
          f"pos_x {forces.pos_x:g}, converged {lo:g}-{hi:g} m/s")
    print(f"Step 3 - V0 rule: {len(q)} grid values qualify ({q.v0.min():g}-{q.v0.max():g} m/s); "
          f"{int((q.t_in_range >= durations[1] - 1e-9).sum())} stay in range for the full {durations[1]:g} s. "
          f"Chosen V0 (PROVISIONAL, pending review) = {v0:g} m/s; V0 x (1 ± {V0_SHIFT}) = "
          f"{v0 * (1 - V0_SHIFT):.3f} / {v0 * (1 + V0_SHIFT):.3f} m/s")
    summary += [dict(metric="attitude_pos_y", value=forces.pos_y), dict(metric="attitude_pos_x", value=forces.pos_x),
                dict(metric="v_range_lo_ms", value=lo), dict(metric="v_range_hi_ms", value=hi),
                dict(metric="v0_ms", value=v0)]
    summary += [dict(sigma_case=c, metric="sigma_x_ms2", value=v) for c, v in sigma.items()]

    # Steps 5-6: runs, coverage and the rtol check.
    specs = {"base": (PLANTED, v0), "k+": (PLANTED * (1 + FRICTION_SHIFT), v0), "k-": (PLANTED * (1 - FRICTION_SHIFT), v0),
             "v0+": (PLANTED, v0 * (1 + V0_SHIFT)), "v0-": (PLANTED, v0 * (1 - V0_SHIFT))}
    runs, curves, rows_delta = {}, {}, []
    for dur in durations:
        t = sample_times(mmc1, dur)
        runs[dur] = {n: run_accel(forces, k, v, dur, t) for n, (k, v) in specs.items()}
        print(f"\nStep 5 - {dur:g} s run, {t.size} sample times:")
        for n, (a, t_reached, _) in runs[dur].items():
            flag = "   !!! COVERS LESS THAN HALF ITS DURATION !!!" if t_reached < HALF * dur else ""
            print(f"  {n:4s} k = {specs[n][0]:.3f}, V0 = {specs[n][1]:.3f} m/s: reached {t_reached:.4f} s, "
                  f"{a.size}/{t.size} samples{flag}")
            summary += [dict(duration_s=dur, run=n, metric="t_reached_s", value=t_reached),
                        dict(duration_s=dur, run=n, metric="samples_covered", value=a.size)]
        n_common = min(a.size for a, _, _ in runs[dur].values())
        tc = t[:n_common]
        d = {n: runs[dur][n][0][:n_common] - runs[dur]["base"][0][:n_common] for n in SHIFTED}
        curves[dur] = (tc, d)
        fine = {n: run_accel(forces, k, v, dur, t, rtol=RTOL_CHECK)[0][:n_common] for n, (k, v) in specs.items()}
        worst = max(np.abs((fine[n] - fine["base"]) - d[n]).max() / np.abs(fine[n] - fine["base"]).max() for n in SHIFTED)
        print(f"  rtol check: tightening rtol {RTOL:g} -> {RTOL_CHECK:g} moves delta-a by at most {worst:.2e} of its "
              f"maximum ({'under' if worst < 0.01 else 'NOT under'} the 1 % limit); {n_common} common samples compared")
        summary.append(dict(duration_s=dur, metric="rtol_check_max_rel_change", value=worst))
        for n in SHIFTED:
            rows_delta.append(pd.DataFrame({"duration_s": dur, "timestamp": tc, "run": n, "d_accel_x_ms2": d[n]}))
    pd.concat(rows_delta, ignore_index=True).to_csv(OUT_DIR / "delta_a.csv", index=False, encoding="utf-8")

    # Step 7: comparison, x only.
    for dur, (tc, d) in curves.items():
        table = []
        for n in SHIFTED:
            peak = float(np.abs(d[n]).max())
            t_peak = float(tc[np.argmax(np.abs(d[n]))])
            frac = majority_sign_fraction(d[n])
            table.append({"run": n, "max|Δa_x| (m/s²)": peak, "at t (s)": t_peak,
                          "max/σ upper bound": peak / sigma["upper"], "max/σ lower bound": peak / sigma["lower"],
                          "majority-sign fraction": frac})
            summary += [dict(duration_s=dur, run=n, metric="max_abs_delta_ax_ms2", value=peak),
                        dict(duration_s=dur, run=n, metric="t_at_max_abs_delta_s", value=t_peak),
                        dict(duration_s=dur, run=n, metric="majority_sign_fraction", value=frac)]
            summary += [dict(duration_s=dur, sigma_case=c, run=n, metric="max_abs_delta_over_sigma",
                             value=peak / sigma[c]) for c in SIGMA_CASES]
        corr = []
        for fr in FRICTION_RUNS:
            for vr in V0_RUNS:
                c = correlation(d[fr], d[vr])
                corr.append({"pair": f"{fr} vs {vr}", "corr a_x": c})
                summary.append(dict(duration_s=dur, run=fr, partner=vr, metric="correlation", value=c))
        print(f"\nStep 7 - {dur:g} s run, x channel, {tc.size} samples:")
        print(pd.DataFrame(table).to_string(index=False, float_format=fmt))
        print(pd.DataFrame(corr).to_string(index=False, float_format=lambda x: f"{x:+.4f}"))
    pd.DataFrame(summary, columns=["duration_s", "sigma_case", "run", "partner", "metric", "value"]).to_csv(
        OUT_DIR / "summary.csv", index=False, encoding="utf-8")

    plot_speed(runs, forces, OUT_DIR / "speed_runs.png")
    plot_delta(curves, sigma, OUT_DIR / "delta_a_x.png")
    plot_overlay(curves, OUT_DIR / "overlay_x.png")

    print("\nAssumptions (stated, not fixed):")
    for a in ASSUMPTIONS:
        print(f"  - {a}")
    print("Conservative readings taken where the brief was open:")
    for r in READINGS:
        print(f"  - {r}")

    # Step 8: Monte Carlo, x only, under a 60-min cap that includes the timing fits.
    mc_start = time.perf_counter()
    clean = {dur: runs[dur]["base"][0] for dur in durations}
    tt = {dur: sample_times(mmc1, dur)[: clean[dur].size] for dur in durations}
    noise = {dur: NoiseDraws(SEED, clean[dur].size) for dur in durations}
    combos = [(dur, case, s) for dur in durations for case in SIGMA_CASES for s in ("a", "b")]
    timing = {}
    print(f"\nStep 8 - timing {FITS_TIMED} fits per combination (seed {SEED}):")
    for dur, case, s in combos:
        t0 = time.perf_counter()
        for i in range(FITS_TIMED):
            fit(forces, clean[dur] + noise[dur][i] * sigma[case], sigma[case], tt[dur], dur, v0, s == "b")
        timing[(dur, case, s)] = (time.perf_counter() - t0) / FITS_TIMED
        print(f"  {dur:g} s, sigma {case}, set ({s}): {timing[(dur, case, s)]:.3f} s per fit")
    out, stats, stops = [], [], {}
    order = sorted(combos, key=lambda c: timing[c])
    for i, (dur, case, s) in enumerate(order):
        allowance = (MC_BUDGET_S - (time.perf_counter() - mc_start)) / (len(order) - i)
        fits, stop = monte_carlo(forces, clean[dur], noise[dur], sigma[case], tt[dur], dur, v0, s == "b",
                                 allowance, timing[(dur, case, s)])
        stops[(dur, case, s)] = stop
        f = pd.DataFrame(fits).assign(duration_s=dur, sigma_case=case, set=s, draw=lambda x: np.arange(len(x)))
        out.append(f)
        tag = "capped by the 60-min limit" if stop["capped"] else ("settled < 5 %" if stop["settled"] else "")
        stats.append({"screen": "this screen: one attitude, trimmed lift (a_x only)", "duration_s": dur, "sigma": case,
                      "set": s, **mc_stats(f, s == "b"), "N (last compare)": stop["n"], "2N": stop["n2"],
                      "sd k (N)": stop["sd_n"], "sd k (2N)": stop["sd_n2"], "doubling": tag,
                      "guard hits": int(f.guard_hits.sum())})
        print(f"  done: {dur:g} s, sigma {case}, set ({s}): {len(f)} fits, {tag}, "
              f"{time.perf_counter() - mc_start:.0f} s of the {MC_BUDGET_S} s budget used")
    # Combinations run in timing order, which varies run to run; sort so the file does not.
    fits_df = pd.concat(out, ignore_index=True)[["duration_s", "sigma_case", "set", "draw", "k_fit", "v0_fit", "converged",
                                                 "at_bound", "guard_hits", "nfev"]].sort_values(
        ["duration_s", "sigma_case", "set", "draw"], ignore_index=True)
    fits_df.to_csv(OUT_DIR / "monte_carlo_fits.csv", index=False, encoding="utf-8")
    plot_fitted_k(fits_df, stops, OUT_DIR / "fitted_k_hist.png")

    this = pd.DataFrame(stats).sort_values(["duration_s", "sigma", "set"])
    this.to_csv(OUT_DIR / "monte_carlo_summary.csv", index=False, encoding="utf-8")
    print(f"\nStep 8 - Monte Carlo, a_x only (seed {SEED}; true k = {PLANTED}, V0 = {v0:g} m/s; starts k = "
          f"{PLANTED * (1 + FRICTION_SHIFT):.3f}, V0 = {v0 * (1 + V0_SHIFT):.3f} m/s in set b):")
    print(this.drop(columns="screen").to_string(index=False, float_format=fmt))
    print(f"\nwrote {OUT_DIR}")


if __name__ == "__main__":
    main()
