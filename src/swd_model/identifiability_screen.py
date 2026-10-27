"""Identifiability screen for the planned inverse PINN.

Three questions, asked before any Blasius, von Karman, RK4 or PINN work is built:

1. If only the *friction* part of the drag is shifted, does the board's acceleration change
   by enough, at the ~15 Hz sample times of the paper's instrumented board (mmc1), to be
   seen above that IMU's noise?
2. Does that change look different from the change caused by shifting the starting speed?
3. How precisely could a least-squares fit recover the friction multiplier ``k`` from noisy
   data sampled like this?

The forward model is :mod:`trajectory` (forward Euler, the ``default_shortboard`` hydroscan
polar, constant slope, raised-cosine roll) with one change: a multiplier ``k`` on the
friction term of the drag. Nothing here gives a pass/fail verdict - it prints the numbers,
and writes them to ``SWD/data/default_shortboard/computed-data/identifiability_screen/``.

Run
---
    python -m src.swd_model.identifiability_screen               # stops before a Monte Carlo over 30 min
    python -m src.swd_model.identifiability_screen --allow-long  # runs it regardless
"""

from __future__ import annotations

import argparse
import sys
import time
import zipfile
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import pandas as pd
from scipy.optimize import least_squares

from src.swd_model import trajectory as tr

# The author's settings (AI-USE.md section 4). Do not change them without asking.
PLANTED = 1.10  # friction multiplier behind the "measured" data: friction 10 % above SWD's
FRICTION_SHIFT = 0.10
V0_SHIFT = 0.20
SLOPE_DEG = 10.0

MMC1 = Path(__file__).resolve().parents[2] / "SWD" / "data" / "paper-supplementary" / "mmc1.zip"
MMC1_COLUMNS = ["t_ms", "sg1", "sg2", "sg3", "sg4", "sg5",
                "ax_g", "ay_g", "az_g", "rx", "ry", "rz"]
OUT_DIR = tr.BOARD_DIR / "computed-data" / "identifiability_screen"
MASS_KG = 80.0 + 1.741  # surfer + board, trajectory.simulate's defaults

# Quiet window confirmed by the author on 2026-10-24: 20 samples from index 22
# (t = 1.498-2.795 s). It includes real motion, so its sigma is an UPPER bound on noise.
QUIET_LENGTH = 20
QUIET_START = 22
# The LOWER bound: mmc1 prints acceleration to 0.01 g, and uniform quantisation of a
# step q has standard deviation q / sqrt(12).
RESOLUTION_SIGMA = 0.01 * tr.G / np.sqrt(12.0)

DT0 = 0.01
DT_REL_TOL = 0.01  # step 3: differences may move by < 1 % of their own maximum
DT_ABS_FLOOR = 1e-9  # m/s^2. a_y differences are round-off (see choose_dt); far below any sigma
DT_MAX_HALVINGS = 8
SEED = 20261024
N0 = 200
N_MAX = 3200
STD_REL_TOL = 0.05
FITS_TIMED = 5
RUNTIME_LIMIT_S = 30 * 60

CHANNELS = ("x", "y", "z")
ACCEL = ["accel_x_ms2", "accel_y_ms2", "accel_z_ms2"]
SHIFTED = ("k+", "k-", "v0+", "v0-")
FRICTION_RUNS, V0_RUNS = ("k+", "k-"), ("v0+", "v0-")
SIGMA_CASES = ("upper", "lower")

# Plot palette: the dataviz reference light slots 1-2 (validated: CVD dE 24.7, contrast >= 3:1).
SURFACE, INK, INK_2, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#e4e3df"
SERIES_1, SERIES_2 = "#2a78d6", "#eb6834"
BAND_UPPER, BAND_LOWER = "#ebeae6", "#cfcec8"

ASSUMPTIONS = (
    "An IMU reads specific force in the board frame, while trajectory.py's accelerations are in "
    "the path frame. Gravity cancels between runs with the same attitude, so the differences are "
    "comparable but the absolute values are not.",
    "The noise sigma is an upper bound (the quiet window includes real motion), so the Monte "
    "Carlo spread is pessimistic. The lower-bound case uses the 0.01 g resolution floor instead.",
    "The noise is assumed independent between samples; the lag-1 autocorrelation of the "
    "detrended quiet-window signal is printed per axis above.",
    "mmc1's board, surfer and wave differ from default_shortboard and the 80 kg surfer.",
    f"The friction speed exponent is trajectory.py's EXP_FRICTION placeholder ({tr.EXP_FRICTION}).",
    "Below the polar's smallest tabulated roll (0.866 deg), np.interp holds the 0.866 deg forces: for about 10 % of "
    "each run (the ends of the roll profile) the forces are held, not measured.",
)


@dataclass(frozen=True)
class FrictionScaledPolar(tr.BoardPolar):
    """A :class:`trajectory.BoardPolar` whose friction drag is multiplied by ``k``.

    Attributes
    ----------
    k : float
        Multiplier on the friction part of the drag only. Lift and planing drag stay SWD's.
    """

    k: float = 1.0

    def drag(self, v: float, roll: np.ndarray | float) -> np.ndarray:
        """Total drag in newtons, with only the friction term scaled by ``k``.

        Parameters
        ----------
        v : float
            Board speed, m/s.
        roll : float or numpy.ndarray
            Roll angle(s), rad.

        Returns
        -------
        numpy.ndarray
            Planing drag plus ``k`` times friction drag, N.
        """
        # Planing is defined as drag_n - friction_n, so scaling friction_n itself would
        # have moved planing by the same amount the other way. Scale the term instead.
        fric = np.interp(np.abs(roll), self.roll_rad, self.friction_n)
        plan = np.interp(np.abs(roll), self.roll_rad, self.drag_n) - fric
        r = v / self.v_ref
        return plan * r**tr.EXP_PLANING + self.k * fric * r**tr.EXP_FRICTION


def simulate(
    polar: tr.BoardPolar,
    k: float = 1.0,
    v0: float | None = None,
    duration_s: float = 3.0,
    dt: float = 0.01,
    t_cover: float | None = None,
    slope_deg: float = SLOPE_DEG,
    mass_kg: float = 80.0,
    board_mass_kg: float = 1.741,
    roll_max_deg: float = 35.0,
) -> pd.DataFrame:
    """One carving turn, as :func:`trajectory.simulate`, with ``k``, ``v0`` and grid length free.

    The loop mirrors ``trajectory.simulate`` line for line, so ``k = 1`` with the default
    ``v0`` reproduces it exactly (``tests/test_identifiability_screen.py`` holds it to that).

    Parameters
    ----------
    polar : trajectory.BoardPolar
        SWD's lift and drag polar.
    k : float
        Friction multiplier.
    v0 : float, optional
        Starting speed, m/s. Default: the equilibrium speed, as in ``trajectory.simulate``.
    duration_s : float
        Length of the carve; it sets the raised-cosine roll period.
    dt : float
        Euler step, s.
    t_cover : float, optional
        Last time the run is compared at. The grid is then extended past it, because
        ``np.arange`` stops short of its end. The roll period stays ``duration_s``.
    slope_deg, mass_kg, board_mass_kg, roll_max_deg : float
        As in ``trajectory.simulate``; the slope defaults to the author's ``SLOPE_DEG``.

    Returns
    -------
    pandas.DataFrame
        ``timestamp``, ``speed_ms``, ``roll_rad`` and the path-frame ``accel_{x,y,z}_ms2``.
    """
    p = FrictionScaledPolar(**{**vars(polar), "k": k})
    m = mass_kg + board_mass_kg
    # Two extra steps put the last compared sample between central differences rather
    # than on np.gradient's one-sided end.
    end = duration_s if t_cover is None else max(duration_s, t_cover + 2.0 * dt)
    t = np.arange(0.0, end, dt)
    if t_cover is not None and t[-1] < t_cover:
        raise ValueError(f"grid ends at {t[-1]} s, before the last sample at {t_cover} s")
    phi = np.radians(roll_max_deg) * 0.5 * (1.0 - np.cos(2.0 * np.pi * t / duration_s))

    v = np.empty_like(t)
    v[0] = tr.equilibrium_speed(p, m, 0.0) if v0 is None else v0
    drive = m * tr.G * np.sin(np.radians(slope_deg))
    for i in range(1, t.size):
        d = float(p.drag(v[i - 1], phi[i - 1]))
        v[i] = max(v[i - 1] + dt * (drive - d) / m, 0.05)

    r = tr.turn_radius(v, phi)
    lift = np.array([float(p.lift(vi, pi)) for vi, pi in zip(v, phi)])
    return pd.DataFrame(
        {
            "timestamp": t,
            "speed_ms": v,
            "roll_rad": phi,
            "accel_x_ms2": np.gradient(v, dt),
            "accel_y_ms2": v**2 / r,
            "accel_z_ms2": (lift - m * tr.G) / m,
        }
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


def at_samples(df: pd.DataFrame, t: np.ndarray) -> np.ndarray:
    """Linearly interpolate a run's three accelerations onto sample times.

    Parameters
    ----------
    df : pandas.DataFrame
        A run from :func:`simulate`.
    t : numpy.ndarray
        Sample times, s, inside the run's grid.

    Returns
    -------
    numpy.ndarray
        Shape ``(len(t), 3)``: accel x, y, z in m/s^2.
    """
    ts = df.timestamp.to_numpy()
    t = np.asarray(t)
    if t.dtype.kind not in "iuf":
        raise ValueError("sample times must be numbers (a bool is not)")
    t = t.astype(float)
    if t.ndim != 1 or t.size == 0 or not np.all(np.isfinite(t)):
        raise ValueError("sample times must be a non-empty 1-D array of finite values")
    # np.interp clamps outside its grid, which would silently hold the last value; min/max, not the ends,
    # so an unsorted t cannot slip a sample past the check
    if t.min() < ts[0] or t.max() > ts[-1]:
        raise ValueError(f"sample times {t.min()}-{t.max()} s fall outside the run {ts[0]}-{ts[-1]} s")
    return np.column_stack([np.interp(t, ts, df[c].to_numpy()) for c in ACCEL])


def run_specs(v0_true: float) -> dict[str, tuple[float, float]]:
    """``(k, v0)`` for the baseline and the four shifted runs of step 2.

    Parameters
    ----------
    v0_true : float
        The baseline starting speed (the equilibrium speed), m/s.

    Returns
    -------
    dict
        Run name -> ``(k, v0)``.
    """
    return {
        "base": (PLANTED, v0_true),
        "k+": (PLANTED * (1 + FRICTION_SHIFT), v0_true),
        "k-": (PLANTED * (1 - FRICTION_SHIFT), v0_true),
        "v0+": (PLANTED, v0_true * (1 + V0_SHIFT)),
        "v0-": (PLANTED, v0_true * (1 - V0_SHIFT)),
    }


def deltas(
    polar: tr.BoardPolar, duration_s: float, dt: float, t: np.ndarray, v0_true: float
) -> dict[str, np.ndarray]:
    """Acceleration differences, shifted run minus baseline, at the sample times.

    Parameters
    ----------
    polar : trajectory.BoardPolar
        SWD's polar.
    duration_s, dt : float
        Carve length and Euler step, s.
    t : numpy.ndarray
        Sample times, s.
    v0_true : float
        Baseline starting speed, m/s.

    Returns
    -------
    dict
        Shifted-run name -> ``(len(t), 3)`` array of delta-a, m/s^2.
    """
    acc = {
        name: at_samples(simulate(polar, k=k, v0=v0, duration_s=duration_s, dt=dt, t_cover=t[-1]), t)
        for name, (k, v0) in run_specs(v0_true).items()
    }
    return {name: acc[name] - acc["base"] for name in SHIFTED}


def choose_dt(
    polar: tr.BoardPolar, duration_s: float, t: np.ndarray, v0_true: float
) -> tuple[float, list[dict], dict[str, np.ndarray]]:
    """Halve dt from ``DT0`` until the delta-a curves stop moving (step 3).

    A step passes when every curve (4 runs x 3 channels) changes by at most 1 % of its
    own maximum. By Eq 64, ``a_y = v^2/R = g tan(phi)`` does not depend on speed, so the
    a_y curves are round-off, and "1 % of round-off" would never settle; the absolute
    floor ``DT_ABS_FLOOR`` covers that case. The finer dt of the passing pair is used.

    Parameters
    ----------
    polar : trajectory.BoardPolar
        SWD's polar.
    duration_s : float
        Carve length, s.
    t : numpy.ndarray
        Sample times, s.
    v0_true : float
        Baseline starting speed, m/s.

    Returns
    -------
    dt : float
        The step used.
    log : list of dict
        One entry per halving: the pair, the worst curve's change against its allowance, and
        the same for the worst x or z curve alone (``*_xz``), so a step decided by a_y
        round-off is visible as such.
    d : dict
        The delta-a curves at ``dt``.

    Raises
    ------
    RuntimeError
        If ``DT_MAX_HALVINGS`` halvings do not converge.
    """
    dt, coarse, log = DT0, deltas(polar, duration_s, DT0, t, v0_true), []
    for _ in range(DT_MAX_HALVINGS):
        fine = deltas(polar, duration_s, dt / 2, t, v0_true)
        worst, worst_xz = None, None
        for name in SHIFTED:
            for c, ch in enumerate(CHANNELS):
                change = float(np.max(np.abs(fine[name][:, c] - coarse[name][:, c])))
                peak = float(np.max(np.abs(fine[name][:, c])))
                allowed = max(DT_REL_TOL * peak, DT_ABS_FLOOR)
                e = dict(run=name, channel=ch, change=change, peak=peak, ratio=change / allowed)
                if worst is None or e["ratio"] > worst["ratio"]:
                    worst = e
                if ch != "y" and (worst_xz is None or e["ratio"] > worst_xz["ratio"]):
                    worst_xz = e
        log.append(dict(dt_coarse=dt, dt_fine=dt / 2, **worst, **{f"{k}_xz": v for k, v in worst_xz.items()}))
        if worst["ratio"] <= 1.0:
            return dt / 2, log, fine
        dt, coarse = dt / 2, fine
    raise RuntimeError(f"dt did not converge after {DT_MAX_HALVINGS} halvings: {log[-1]}")


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
    acc = mmc1[["ax_g", "ay_g", "az_g"]].to_numpy() * tr.G  # g, gravity included -> m/s^2
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


def residuals(
    params: np.ndarray,
    polar: tr.BoardPolar,
    data: np.ndarray,
    sigma: np.ndarray,
    t: np.ndarray,
    duration_s: float,
    dt: float,
    v0_fixed: float | None,
) -> np.ndarray:
    """Noise-weighted misfit of the forward model, all three channels together.

    Parameters
    ----------
    params : numpy.ndarray
        ``[k]`` when ``v0_fixed`` is given, else ``[k, v0]``.
    polar : trajectory.BoardPolar
        SWD's polar.
    data : numpy.ndarray
        ``(len(t), 3)`` accelerations being fitted, m/s^2.
    sigma : numpy.ndarray
        Per-channel noise standard deviation, m/s^2.
    t : numpy.ndarray
        Sample times, s.
    duration_s, dt : float
        Carve length and Euler step, s.
    v0_fixed : float or None
        Starting speed held fixed (set a), or None to fit it (set b).

    Returns
    -------
    numpy.ndarray
        Flattened ``(model - data) / sigma``.
    """
    k, v0 = (params[0], v0_fixed) if v0_fixed is not None else (params[0], params[1])
    model = at_samples(simulate(polar, k=k, v0=v0, duration_s=duration_s, dt=dt, t_cover=t[-1]), t)
    return ((model - data) / sigma).ravel()


def fit(
    polar: tr.BoardPolar,
    data: np.ndarray,
    sigma: np.ndarray,
    t: np.ndarray,
    duration_s: float,
    dt: float,
    v0_true: float,
    joint: bool,
) -> tuple[float, float, bool]:
    """Fit ``k`` (set a) or ``k`` and ``v0`` jointly (set b), from deliberately wrong starts.

    Parameters
    ----------
    polar : trajectory.BoardPolar
        SWD's polar.
    data : numpy.ndarray
        ``(len(t), 3)`` accelerations, m/s^2.
    sigma : numpy.ndarray
        Per-channel noise standard deviation, m/s^2.
    t : numpy.ndarray
        Sample times, s.
    duration_s, dt : float
        Carve length and Euler step, s.
    v0_true : float
        True starting speed: held fixed in set a, perturbed for the start in set b.
    joint : bool
        True for set b.

    Returns
    -------
    k_fit : float
        Fitted friction multiplier.
    v0_fit : float
        Fitted starting speed (NaN for set a).
    converged : bool
        ``least_squares``'s own success flag.
    """
    # Start from the shifted values, not the truth, so a fit cannot pass by never moving.
    x0 = [PLANTED * (1 + FRICTION_SHIFT)] + ([v0_true * (1 + V0_SHIFT)] if joint else [])
    res = least_squares(
        residuals, x0, bounds=(0.0, np.inf),  # TRF keeps iterates strictly inside, so k, v0 > 0
        args=(polar, data, sigma, t, duration_s, dt, None if joint else v0_true),
    )
    return float(res.x[0]), float(res.x[1]) if joint else float("nan"), bool(res.success)


def monte_carlo(
    polar: tr.BoardPolar,
    clean: np.ndarray,
    noise: np.ndarray,
    sigma: np.ndarray,
    t: np.ndarray,
    duration_s: float,
    dt: float,
    v0_true: float,
    joint: bool,
) -> tuple[list[tuple[float, float, bool]], dict]:
    """Fit noisy copies of the baseline, doubling N until the spread of ``k`` settles.

    Draw ``i`` is always ``noise[i]``, so the first N of 2N are the same fits (nested).

    Parameters
    ----------
    polar : trajectory.BoardPolar
        SWD's polar.
    clean : numpy.ndarray
        Baseline accelerations at the sample times, ``(len(t), 3)``.
    noise : numpy.ndarray
        Standard-normal draws, ``(N_MAX, len(t), 3)``; scaled here by ``sigma``.
    sigma : numpy.ndarray
        Per-channel noise standard deviation, m/s^2.
    t : numpy.ndarray
        Sample times, s.
    duration_s, dt : float
        Carve length and Euler step, s.
    v0_true : float
        True starting speed, m/s.
    joint : bool
        True for set b.

    Returns
    -------
    fits : list of tuple
        ``(k_fit, v0_fit, converged)`` per draw, in draw order.
    stop : dict
        ``n``, ``n2``, ``sd_n``, ``sd_n2`` from the last doubling, and whether it ``settled``.
    """
    fits: list[tuple[float, float, bool]] = []

    def sd_k(n: int) -> float:
        """Standard deviation (ddof 1) of the converged fitted k among the first ``n`` draws."""
        k = [f[0] for f in fits[:n] if f[2]]
        return float(np.std(k, ddof=1)) if len(k) > 1 else float("nan")

    n = N0
    while True:
        while len(fits) < 2 * n:
            i = len(fits)
            fits.append(fit(polar, clean + noise[i] * sigma, sigma, t, duration_s, dt, v0_true, joint))
        sd_n, sd_n2 = sd_k(n), sd_k(2 * n)
        # sd_n = 0 (no spread at all) is not "settled"; the live screen guards it the same way
        settled = sd_n > 0 and abs(sd_n2 - sd_n) / sd_n < STD_REL_TOL
        if settled or 2 * n >= N_MAX:
            return fits, dict(n=n, n2=2 * n, sd_n=sd_n, sd_n2=sd_n2, settled=settled)
        n *= 2


def plot_delta_a(t: np.ndarray, d: dict, sigma: dict, duration_s: float, path: Path) -> None:
    """Delta-a at the sample times against both +/- sigma bands, friction and V0 apart.

    Parameters
    ----------
    t : numpy.ndarray
        Sample times, s.
    d : dict
        Delta-a curves from :func:`deltas`.
    sigma : dict
        ``"upper"`` / ``"lower"`` -> per-channel sigma, m/s^2.
    duration_s : float
        Run length, for the title.
    path : pathlib.Path
        PNG to write.
    """
    import matplotlib.pyplot as plt

    fig, axes = plt.subplots(3, 2, figsize=(11, 8.5), sharex=True, constrained_layout=True)
    for row, ch in enumerate(CHANNELS):
        for col, (title, (plus, minus)) in enumerate(
            (("Friction shift", FRICTION_RUNS), ("Starting-speed shift", V0_RUNS))
        ):
            ax = axes[row, col]
            peak = max(np.abs(d[plus][:, row]).max(), np.abs(d[minus][:, row]).max())
            # Scale to the signal (or the lower band), so a curve buried in the upper
            # band is still visible; the clipped band is flagged in the panel.
            lim = 1.15 * max(peak, sigma["lower"][row])
            for case, colour in (("upper", BAND_UPPER), ("lower", BAND_LOWER)):
                s = sigma[case][row]
                ax.axhspan(-s, s, color=colour, lw=0, label=f"±σ {case} bound ({s:.3g} m/s²)")
            if sigma["upper"][row] > lim:
                ax.text(0.99, 0.04, "upper-bound band extends past this axis", ha="right",
                        transform=ax.transAxes, fontsize=8, color=INK_2)
            ax.plot(t, d[plus][:, row], color=SERIES_1, lw=1.5, marker="o", ms=4, label=RUN_LABEL[plus])
            ax.plot(t, d[minus][:, row], color=SERIES_2, lw=1.5, ls="--", marker="s", ms=4,
                    label=RUN_LABEL[minus])
            ax.set_ylim(-lim, lim)
            ax.set_ylabel(f"Δa_{ch} (m/s²)")
            if row == 0:
                ax.set_title(title)
                ax.legend(fontsize=8, loc="upper right")
            if row == 2:
                ax.set_xlabel("time from first sample (s)")
    fig.suptitle(f"Shifted run minus baseline at mmc1 sample times, {duration_s:g} s run")
    fig.savefig(path, dpi=150)
    plt.close(fig)


def plot_overlay(t: np.ndarray, d: dict, duration_s: float, path: Path) -> None:
    """The friction and V0 delta-a curves, each normalised by its own maximum, overlaid.

    Parameters
    ----------
    t : numpy.ndarray
        Sample times, s.
    d : dict
        Delta-a curves from :func:`deltas`; the ``k+`` and ``v0+`` curves are drawn.
    duration_s : float
        Run length, for the title.
    path : pathlib.Path
        PNG to write.
    """
    import matplotlib.pyplot as plt

    fig, axes = plt.subplots(3, 1, figsize=(9, 8.5), sharex=True, constrained_layout=True)
    for row, ch in enumerate(CHANNELS):
        ax = axes[row]
        for name, colour, ls, mk in (("k+", SERIES_1, "-", "o"), ("v0+", SERIES_2, "--", "s")):
            y = d[name][:, row]
            peak = np.abs(y).max()
            ax.plot(t, y / peak if peak > 0 else y, color=colour, lw=1.5, ls=ls, marker=mk, ms=4,
                    label=f"{RUN_LABEL[name]}  (max |Δa| = {peak:.3g} m/s²)")
        ax.axhline(0.0, color=INK_2, lw=0.8)
        ax.set_ylabel(f"Δa_{ch} / max|Δa_{ch}|")
        title = f"a_{ch}: corr = {correlation(d['k+'][:, row], d['v0+'][:, row]):+.3f}"
        if ch == "y":
            # Normalising blows these up to ±1; say what they are before anyone reads them as signal.
            title += "\n(a_y = g·tan φ has no speed dependence; this is round-off and the R = 1e9 m clip at φ = 0)"
        ax.set_title(title, fontsize=10)
        ax.legend(fontsize=8, loc="best")
    axes[-1].set_xlabel("time from first sample (s)")
    fig.suptitle(f"Shape of the friction and starting-speed signatures, {duration_s:g} s run")
    fig.savefig(path, dpi=150)
    plt.close(fig)


def plot_fitted_k(fits: pd.DataFrame, path: Path) -> None:
    """Histograms of the converged fitted ``k``: sets a and b per duration and sigma case.

    Parameters
    ----------
    fits : pandas.DataFrame
        Every Monte Carlo fit, as written to ``monte_carlo_fits.csv``.
    path : pathlib.Path
        PNG to write.
    """
    import matplotlib.pyplot as plt

    durations = sorted(fits.duration_s.unique())
    band = FRICTION_SHIFT * PLANTED
    fig, axes = plt.subplots(len(durations), 2, figsize=(11, 4 * len(durations)),
                             squeeze=False, constrained_layout=True)
    for i, dur in enumerate(durations):
        for j, case in enumerate(SIGMA_CASES):
            ax = axes[i, j]
            sub = fits[(fits.duration_s == dur) & (fits.sigma_case == case) & fits.converged]
            ax.axvspan(PLANTED - band, PLANTED + band, color=BAND_UPPER, lw=0,
                       label=f"PLANTED ± FRICTION_SHIFT × PLANTED (±{band:.2f})")
            ax.axvline(PLANTED, color=INK, lw=1.5, label=f"planted k = {PLANTED}")
            edges = np.linspace(sub.k_fit.min(), sub.k_fit.max(), 41)
            top = 0
            for s, colour, ls in (("a", SERIES_1, "-"), ("b", SERIES_2, "--")):
                k = sub[sub.set == s].k_fit
                counts, _, _ = ax.hist(k, bins=edges, histtype="step", lw=1.5, ls=ls, color=colour,
                                       label=f"set ({s}): mean {k.mean():.4f}, sd {k.std(ddof=1):.3g}, n = {k.size}")
                top = max(top, counts.max())
            ax.set_ylim(0, 1.8 * top)  # headroom so the legend clears the bars
            ax.set_title(f"{dur:g} s run, sigma {case} bound", fontsize=10)
            ax.set_xlabel("fitted k")
            ax.set_ylabel("draws")
            ax.legend(fontsize=8, loc="upper left")
    fig.suptitle("Fitted friction multiplier over noise draws (converged fits)")
    fig.savefig(path, dpi=150)
    plt.close(fig)


RUN_LABEL = {
    "k+": f"k = {PLANTED * (1 + FRICTION_SHIFT):.3f} (friction +{FRICTION_SHIFT:.0%})",
    "k-": f"k = {PLANTED * (1 - FRICTION_SHIFT):.3f} (friction −{FRICTION_SHIFT:.0%})",
    "v0+": f"V0 × {1 + V0_SHIFT:g}",
    "v0-": f"V0 × {1 - V0_SHIFT:g}",
}

RC = {
    "figure.facecolor": SURFACE, "axes.facecolor": SURFACE, "savefig.facecolor": SURFACE,
    "axes.edgecolor": INK_2, "axes.labelcolor": INK, "text.color": INK,
    "xtick.color": INK_2, "ytick.color": INK_2, "axes.grid": True, "grid.color": GRID,
    "grid.linewidth": 0.6, "axes.axisbelow": True, "legend.frameon": False,
    "axes.spines.top": False, "axes.spines.right": False,
}


def main(argv: list[str] | None = None) -> None:
    """Run the screen end to end and write its outputs.

    Parameters
    ----------
    argv : list of str, optional
        Command-line arguments; ``--allow-long`` runs a Monte Carlo projected over 30 min.
    """
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--allow-long", action="store_true", help="run the Monte Carlo even if projected over 30 min")
    args = ap.parse_args(argv)
    # A redirected Windows console is cp1252, which cannot print the σ, Δ and √ in the tables.
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

    import matplotlib

    matplotlib.use("Agg")
    matplotlib.rcParams.update(RC)
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    pd.set_option("display.width", 200)
    pd.set_option("display.max_columns", 30)

    polar = tr.load_polar()
    mmc1 = load_mmc1()
    v0_true = tr.equilibrium_speed(polar, MASS_KG)
    durations = (3.0, float(mmc1.t_s.iloc[-1]))

    # Step 5 - noise. The window was confirmed by the author; refuse if the search moved.
    qw = quiet_window(mmc1)
    if qw["start"] != QUIET_START:
        raise RuntimeError(f"quiet-window search now lands on index {qw['start']}, not the "
                           f"confirmed {QUIET_START}; re-confirm the window with the author")
    sigma = {"upper": qw["sigma"], "lower": np.full(3, RESOLUTION_SIGMA)}

    print("=== Identifiability screen ===")
    print(f"PLANTED = {PLANTED}, FRICTION_SHIFT = {FRICTION_SHIFT}, V0_SHIFT = {V0_SHIFT}, "
          f"SLOPE_DEG = {SLOPE_DEG}, mass = {MASS_KG} kg")
    print(f"V0 (equilibrium) = {v0_true:.4f} m/s; shifted V0 = {v0_true * (1 + V0_SHIFT):.4f} / "
          f"{v0_true * (1 - V0_SHIFT):.4f} m/s")
    fric0 = float(np.interp(0.0, polar.roll_rad, polar.friction_n)) * (v0_true / polar.v_ref) ** tr.EXP_FRICTION
    print(f"Friction share of drag at V0, roll 0, in this polar: {fric0 / float(polar.drag(v0_true, 0.0)):.1%} "
          "(every friction delta-a scales with it)")
    print(f"mmc1: {len(mmc1)} rows, span {durations[1]:.3f} s; durations screened: {durations}")
    print(f"\nStep 5 - quiet window ({QUIET_LENGTH} samples, confirmed): index {qw['start']}-"
          f"{qw['start'] + QUIET_LENGTH - 1}, t = {qw['t0']:.3f}-{qw['t1']:.3f} s")
    print(pd.DataFrame({"sigma upper bound (m/s²)": sigma["upper"],
                        "sigma lower bound (m/s²)": sigma["lower"],
                        "lag-1 autocorrelation": qw["lag1"]}, index=list(CHANNELS)).round(4))
    print("The upper bound includes real motion; the lower bound is the 0.01 g resolution floor "
          f"(0.01 g × {tr.G} / √12 = {RESOLUTION_SIGMA:.4f} m/s²).")

    # Steps 2-3 - runs and step size.
    screen = {}
    for dur in durations:
        t = sample_times(mmc1, dur)
        dt, log, d = choose_dt(polar, dur, t, v0_true)
        screen[dur] = dict(t=t, dt=dt, d=d)
        print(f"\nStep 3 - {dur:g} s run, {t.size} sample times (last {t[-1]:.3f} s):")
        for e in log:
            print(f"  dt {e['dt_coarse']:.6g} -> {e['dt_fine']:.6g}: worst curve {e['run']} a_{e['channel']} "
                  f"moved {e['change']:.3g} m/s² against max |Δa| {e['peak']:.3g} "
                  f"({e['ratio']:.3g} × allowance); worst x/z curve {e['run_xz']} a_{e['channel_xz']} "
                  f"moved {e['change_xz']:.3g} against {e['peak_xz']:.3g} ({e['ratio_xz']:.3g} × allowance)")
        print(f"  dt used: {dt:.6g} s")

    # Step 6 - comparison, both sigma cases side by side.
    rows, curves = [], []
    for dur, s in screen.items():
        t, d = s["t"], s["d"]
        rows.append(dict(duration_s=dur, metric="dt_s", value=s["dt"]))
        for case in SIGMA_CASES:
            for c, ch in enumerate(CHANNELS):
                rows.append(dict(duration_s=dur, sigma_case=case, channel=ch, metric="sigma_ms2",
                                 value=sigma[case][c]))
        table = []
        for name in SHIFTED:
            curves.append(pd.DataFrame({"duration_s": dur, "timestamp": t, "run": name,
                                        **{f"d_{a}": d[name][:, c] for c, a in enumerate(ACCEL)}}))
            for c, ch in enumerate(CHANNELS):
                peak = float(np.max(np.abs(d[name][:, c])))
                # Where the maximum sits matters: at t = 0 it is one sample, not a sustained signal.
                t_peak = float(t[np.argmax(np.abs(d[name][:, c]))])
                frac = majority_sign_fraction(d[name][:, c])
                rows.append(dict(duration_s=dur, channel=ch, metric="max_abs_delta_ms2", run=name, value=peak))
                rows.append(dict(duration_s=dur, channel=ch, metric="t_at_max_abs_delta_s", run=name, value=t_peak))
                for case in SIGMA_CASES:
                    rows.append(dict(duration_s=dur, sigma_case=case, channel=ch,
                                     metric="max_abs_delta_over_sigma", run=name, value=peak / sigma[case][c]))
                rows.append(dict(duration_s=dur, channel=ch, metric="majority_sign_fraction", run=name, value=frac))
                table.append({"run": name, "channel": ch, "max|Δa| (m/s²)": peak, "at t (s)": t_peak,
                              "max|Δa|/σ upper bound": peak / sigma["upper"][c],
                              "max|Δa|/σ lower bound": peak / sigma["lower"][c],
                              "majority-sign fraction": frac})
        corr = []
        for f in FRICTION_RUNS:
            for v in V0_RUNS:
                r = {"pair": f"{f} vs {v}"}
                for c, ch in enumerate(CHANNELS):
                    r[f"a_{ch}"] = correlation(d[f][:, c], d[v][:, c])
                    rows.append(dict(duration_s=dur, channel=ch, metric="correlation", run=f, partner=v,
                                     value=r[f"a_{ch}"]))
                corr.append(r)
        print(f"\nStep 6 - {dur:g} s run, {t.size} samples:")
        print(pd.DataFrame(table).to_string(index=False, float_format=lambda x: f"{x:.4g}"))
        print("Correlation of the friction and V0 delta-a curves (shape similarity):")
        print(pd.DataFrame(corr).to_string(index=False, float_format=lambda x: f"{x:+.4f}"))
        print(f"  a_y: by Eq 64 a_y = g·tan(phi), independent of speed; measured max |Δa_y| over the "
              f"four runs = {max(np.abs(d[n][:, 1]).max() for n in SHIFTED):.3g} m/s² (not fixed here).")
        plot_delta_a(t, d, sigma, dur, OUT_DIR / f"delta_a_{dur:g}s.png")
        plot_overlay(t, d, dur, OUT_DIR / f"overlay_{dur:g}s.png")

    summary = pd.DataFrame(rows, columns=["duration_s", "sigma_case", "channel", "metric", "run", "partner", "value"])
    summary.to_csv(OUT_DIR / "summary.csv", index=False, encoding="utf-8")
    pd.concat(curves, ignore_index=True).to_csv(OUT_DIR / "delta_a.csv", index=False, encoding="utf-8")

    print("\nAssumptions (stated, not fixed):")
    for a in ASSUMPTIONS:
        print(f"  - {a}")

    # Step 7 - time a few fits before committing to the loop.
    rng_noise, clean = {}, {}
    for dur, s in screen.items():
        t = s["t"]
        clean[dur] = at_samples(simulate(polar, k=PLANTED, v0=v0_true, duration_s=dur, dt=s["dt"], t_cover=t[-1]), t)
        # Fresh per duration; shared by both sets and both sigma cases, so they see the same draws.
        rng_noise[dur] = np.random.default_rng(SEED).standard_normal((N_MAX, t.size, 3))
    projected = 0.0
    print(f"\nStep 7 - timing {FITS_TIMED} fits per duration and set (sigma upper bound):")
    for dur, s in screen.items():
        for joint in (False, True):
            t0 = time.perf_counter()
            for i in range(FITS_TIMED):
                fit(polar, clean[dur] + rng_noise[dur][i] * sigma["upper"], sigma["upper"], s["t"], dur,
                    s["dt"], v0_true, joint)
            per_fit = (time.perf_counter() - t0) / FITS_TIMED
            projected += per_fit * 2 * N0 * len(SIGMA_CASES)
            print(f"  {dur:g} s, set ({'b' if joint else 'a'}): {per_fit:.3f} s per fit")
    print(f"  projected minimum total (N = {N0} -> {2 * N0} per set, both sigma cases): "
          f"{projected / 60:.1f} min; each further doubling adds about as much again as the stage before")
    if projected > RUNTIME_LIMIT_S and not args.allow_long:
        print(f"  STOP: over the {RUNTIME_LIMIT_S // 60} min limit. Monte Carlo not run "
              "(re-run with --allow-long once a speed-up is agreed).")
        return

    out, stats = [], []
    for dur, s in screen.items():
        for case in SIGMA_CASES:
            for joint in (False, True):
                set_name = "b" if joint else "a"
                fits, stop = monte_carlo(polar, clean[dur], rng_noise[dur], sigma[case], s["t"], dur, s["dt"],
                                         v0_true, joint)
                f = pd.DataFrame(fits, columns=["k_fit", "v0_fit", "converged"])
                out.append(f.assign(duration_s=dur, sigma_case=case, set=set_name, draw=np.arange(len(f))))
                ok = f[f.converged]
                sd_k = ok.k_fit.std(ddof=1)
                sd_v0 = ok.v0_fit.std(ddof=1) if joint else np.nan
                corr = correlation(ok.k_fit.to_numpy(), ok.v0_fit.to_numpy()) if joint else np.nan
                se = standard_error
                stats.append({
                    "duration_s": dur, "sigma": case, "set": set_name,
                    "N": stop["n"], "2N": stop["n2"], "sd k (N)": stop["sd_n"], "sd k (2N)": stop["sd_n2"],
                    "settled <5%": stop["settled"],
                    "mean k": ok.k_fit.mean(), "SE mean k": se("mean", sd_k, len(ok)),
                    "sd k": sd_k, "SE sd k": se("sd", sd_k, len(ok)),
                    "sd k / (shift×PLANTED)": sd_k / (FRICTION_SHIFT * PLANTED),
                    "converged": f.converged.mean(), "SE converged": se("fraction", f.converged.mean(), len(f)),
                    "mean V0": ok.v0_fit.mean() if joint else np.nan, "SE mean V0": se("mean", sd_v0, len(ok)),
                    "sd V0": sd_v0, "SE sd V0": se("sd", sd_v0, len(ok)),
                    "corr(k, V0)": corr, "SE corr(k, V0)": se("corr", corr, len(ok)),
                })
                print(f"  done: {dur:g} s, sigma {case}, set ({set_name}), {len(f)} fits")
    fits_df = pd.concat(out, ignore_index=True)[["duration_s", "sigma_case", "set", "draw", "k_fit", "v0_fit", "converged"]]
    fits_df.to_csv(OUT_DIR / "monte_carlo_fits.csv", index=False, encoding="utf-8")
    plot_fitted_k(fits_df, OUT_DIR / "fitted_k_hist.png")

    print(f"\nStep 7 - Monte Carlo (seed {SEED}; true V0 = {v0_true:.4f} m/s; "
          f"start k = {PLANTED * (1 + FRICTION_SHIFT):.3f}, start V0 = {v0_true * (1 + V0_SHIFT):.4f} m/s in set b):")
    print(pd.DataFrame(stats).to_string(index=False, float_format=lambda x: f"{x:.5g}"))
    print(f"\nwrote {OUT_DIR}")


if __name__ == "__main__":
    main()
