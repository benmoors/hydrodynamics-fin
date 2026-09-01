"""Trajectory velocity and the two performance indicators, from one SWD board.

SWD stores no time axis. Its 11 reports per board are converged static equilibria,
one per drift angle, so ``Vt(t)`` cannot be extracted - it has to be computed. This
module does that, and is explicit about which parts are SWD's and which are ours:

* **From SWD (measured):** lift and drag against roll and drift, at the scan's
  single reference speed, read from the extracted CSVs.
* **From the vendor's published method (cited):** Eq 64,
  ``R = V^2 / (tan(phi) * 9.81)``, turning roll angle into trajectory curvature.
* **From the scientific article (cited):** Charles et al. (2026), *Results in
  Engineering* 29:108868, Eq 4-7 for Board-Jerk and Eq 10-11 for Radicality.
* **Ours (assumption):** the roll schedule ``phi(t)`` - the manoeuvre itself - and
  the speed exponents used to scale force off the reference speed.

That last point is the honest limit of this module. SWD supplies the force
*response*; it does not supply the manoeuvre, and it never ran at more than one
speed, so any ``V`` dependence here is a modelling choice rather than a measurement.

Run
---
    python SWD/model/trajectory.py            # writes computed-data/trajectory.csv, self-checks
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import numpy as np
import pandas as pd
from scipy.integrate import cumulative_trapezoid, simpson
from scipy.optimize import brentq

G = 9.81
BOARD_DIR = Path(__file__).resolve().parents[1] / "data" / "default_shortboard"

# Force scaling off the scan's reference speed.
#
# Planing follows from the published equations directly: Qm = rho*S*Vr (Eq 21) and
# Vdx, Vdy are both proportional to Vr (Eq 23, 24), so F ~ V^2 exactly.
#
# Friction does NOT: skin friction carries a Reynolds dependence, giving an
# exponent nearer 1.8 for a turbulent flat plate. SWD's actual correlation is a
# compiled-in constant - no ITTC/Schoenherr/0.075/0.455 string exists anywhere in
# the binary - so 1.85 is a placeholder, flagged here rather than buried.
EXP_PLANING = 2.0
EXP_FRICTION = 1.85  # ASSUMPTION pending recovery of SWD's friction law


@dataclass(frozen=True)
class BoardPolar:
    """Lift and drag against roll angle at one drift, from SWD's own output.

    Attributes
    ----------
    roll_rad : np.ndarray
        Mean roll inclination of each roll case, ascending.
    lift_n, drag_n, friction_n : np.ndarray
        Summed element forces for each roll case, in newtons, at ``v_ref``.
    v_ref : float
        Reference flow speed the scan was computed at, m/s.
    """

    roll_rad: np.ndarray
    lift_n: np.ndarray
    drag_n: np.ndarray
    friction_n: np.ndarray
    v_ref: float

    def lift(self, v: float, roll: np.ndarray | float) -> np.ndarray:
        """Lift in newtons at speed ``v`` and roll angle(s) ``roll``."""
        base = np.interp(np.abs(roll), self.roll_rad, self.lift_n)
        return base * (v / self.v_ref) ** EXP_PLANING

    def drag(self, v: float, roll: np.ndarray | float) -> np.ndarray:
        """Total drag in newtons, scaling the friction and planing parts apart."""
        fric = np.interp(np.abs(roll), self.roll_rad, self.friction_n)
        plan = np.interp(np.abs(roll), self.roll_rad, self.drag_n) - fric
        r = v / self.v_ref
        return plan * r**EXP_PLANING + fric * r**EXP_FRICTION


def load_polar(board_dir: Path = BOARD_DIR, drift_deg: float = 0.0) -> BoardPolar:
    """Build a :class:`BoardPolar` from the extracted element CSV.

    Roll is aggregated from ``inclinaison_roulis_rad_ligne_attack`` rather than read
    from ``operating_points.csv``, so the roll axis comes from the same rows the
    forces do.
    """
    e = pd.read_csv(board_dir / "elements.csv")
    e = e[e.drift_deg == drift_deg]
    if e.empty:
        raise ValueError(f"no rows at drift_deg={drift_deg}")
    g = e.groupby("roll_case").agg(
        roll_rad=("inclinaison_roulis_rad_ligne_attack", "mean"),
        lift_n=("portance_globale_verticale_n", "sum"),
        drag_n=("trainee_globale_horizontale_n", "sum"),
        friction_n=("Fx_friction_n", "sum"),
        v=("scan_speed_ms", "median"),
    )
    g = g.assign(roll_rad=g.roll_rad.abs()).sort_values("roll_rad")
    return BoardPolar(
        roll_rad=g.roll_rad.to_numpy(),
        lift_n=g.lift_n.to_numpy(),
        drag_n=g.drag_n.to_numpy(),
        friction_n=g.friction_n.to_numpy(),
        v_ref=float(g.v.median()),
    )


def equilibrium_speed(polar: BoardPolar, mass_kg: float, roll_rad: float = 0.0) -> float:
    """Speed at which planing lift carries the surfer-plus-board weight.

    Solves ``lift(v) = mass*g`` by Brent's method. Lift rises monotonically with
    ``v``, so the root is unique on the bracket.
    """
    w = mass_kg * G
    f = lambda v: float(polar.lift(v, roll_rad)) - w
    lo, hi = 0.1, 50.0
    if f(lo) > 0:
        return lo
    if f(hi) < 0:
        raise ValueError("weight exceeds available lift below 50 m/s")
    return float(brentq(f, lo, hi, xtol=1e-6))


def turn_radius(v: np.ndarray, roll_rad: np.ndarray) -> np.ndarray:
    """Turn radius from roll, per the vendor's Eq 64: ``R = V^2/(tan(phi)*g)``.

    A roll of exactly zero gives an infinite radius; it is clipped to a large
    finite value so that ``yaw rate = V/R`` stays finite and the integration below
    does not produce inf/NaN.
    """
    t = np.tan(np.abs(roll_rad))
    return np.where(t < 1e-6, 1e9, v**2 / (np.maximum(t, 1e-6) * G))


def simulate(
    polar: BoardPolar,
    mass_kg: float = 80.0,
    board_mass_kg: float = 1.741,
    slope_deg: float = 12.0,
    roll_max_deg: float = 35.0,
    duration_s: float = 3.0,
    dt: float = 0.01,
) -> pd.DataFrame:
    """Integrate one carving turn at 100 Hz.

    The manoeuvre is a single smooth carve: roll follows a raised cosine from 0 to
    ``roll_max_deg`` and back. That profile - not a half-sine - is used because its
    derivative vanishes at both ends, so the roll rate is zero at the start and end
    of the manoeuvre and the article's ``t0``/``t1`` turn bounds are well defined.
    A half-sine starts at maximum roll rate, which leaves ``t0`` undefined.

    Speed follows SWD's own documented trajectory model - gravity along the wave
    slope accelerating, drag decelerating, integrated as momentum impulses:
    ``m dV/dt = m g sin(slope) - D(V, phi)``.
    """
    m = mass_kg + board_mass_kg
    t = np.arange(0.0, duration_s, dt)
    phi = np.radians(roll_max_deg) * 0.5 * (1.0 - np.cos(2.0 * np.pi * t / duration_s))

    v = np.empty_like(t)
    v[0] = equilibrium_speed(polar, m, 0.0)
    drive = m * G * np.sin(np.radians(slope_deg))
    for i in range(1, t.size):
        d = float(polar.drag(v[i - 1], phi[i - 1]))
        v[i] = max(v[i - 1] + dt * (drive - d) / m, 0.05)

    r = turn_radius(v, phi)
    lift = np.array([float(polar.lift(vi, pi)) for vi, pi in zip(v, phi)])

    return pd.DataFrame(
        {
            "timestamp": t,
            "speed_ms": v,
            "roll_rad": phi,
            "turn_radius_m": r,
            "lift_force_n": lift,
            "yaw_rate_rad_s": v / r,
            "roll_rate_rad_s": np.gradient(phi, dt),
            "accel_x_ms2": np.gradient(v, dt),
            "accel_y_ms2": v**2 / r,
            "accel_z_ms2": (lift - m * G) / m,
        }
    )


def board_jerk(df: pd.DataFrame) -> float:
    """Dimensionless Board-Jerk cost ``J`` - Charles et al. (2026) Eq 4-7.

    ``D`` is the double integral of acceleration (net displacement), per the
    paper's Eq 7. ``mma3001-project-spec.md`` uses arc length instead; that is a
    different quantity and it enters ``J`` squared through ``C = T^5/D^2``.
    """
    t = df.timestamp.to_numpy()
    dt = float(t[1] - t[0])
    T = float(t[-1] - t[0])
    a = [df.accel_x_ms2.to_numpy(), df.accel_y_ms2.to_numpy(), df.accel_z_ms2.to_numpy()]

    j2 = sum(np.gradient(ai, dt) ** 2 for ai in a)
    pos = [
        cumulative_trapezoid(cumulative_trapezoid(ai, dx=dt, initial=0.0), dx=dt, initial=0.0)[-1]
        for ai in a
    ]
    D = float(np.sqrt(sum(p**2 for p in pos)))
    C = (T**5) / D**2 if D > 0 else 1.0
    return float(simpson(C * j2 / 2.0, dx=dt))


def radicality(df: pd.DataFrame) -> float:
    """Manoeuvre Radicality ``Ra`` in rad^2/s - Charles et al. (2026) Eq 10-11.

    ``t0`` and ``t1`` bound the turn at the zero-crossings of the roll rate
    (Sec 2.3.3); ``Ra = theta_z^2 / (t1 - t0)``.
    """
    t = df.timestamp.to_numpy()
    rr = df.roll_rate_rad_s.to_numpy()

    # np.sign returns 0 at an exact zero, so a single crossing shows up as TWO
    # adjacent transitions (+ -> 0 and 0 -> -). Taking first and last then
    # collapses the window to one sample. Detect strict sign reversals instead,
    # and merge crossings that are adjacent samples of the same event.
    strict = np.where(rr[:-1] * rr[1:] < 0)[0]
    zeros = np.where(rr == 0.0)[0]
    cross = np.unique(np.concatenate([strict, zeros])) if zeros.size else strict
    if cross.size:
        keep = [cross[0]]
        for c in cross[1:]:
            if c - keep[-1] > 1:
                keep.append(c)
        cross = np.array(keep)

    i0, i1 = (cross[0], cross[-1]) if cross.size >= 2 else (0, t.size - 1)
    if i1 - i0 < 2:
        i0, i1 = 0, t.size - 1
    dur = float(t[i1] - t[i0])
    theta_z = float(simpson(df.yaw_rate_rad_s.to_numpy()[i0 : i1 + 1], x=t[i0 : i1 + 1]))
    return theta_z**2 / dur if dur > 0 else 0.0


def _self_check() -> None:
    """Smallest checks that fail if the physics or the article equations break."""
    # Eq 64 against a hand-computed case: 10 m/s at 45 deg roll -> R = 100/9.81.
    assert np.isclose(turn_radius(np.array([10.0]), np.array([np.pi / 4]))[0], 100 / G, rtol=1e-6)

    # Constant-radius turn has the closed form theta_z = V*T/R, Ra = theta_z^2/T.
    n, dt_, v_, r_ = 301, 0.01, 8.0, 5.0
    t_ = np.arange(n) * dt_
    tri = 0.5 * (1.0 - np.cos(2.0 * np.pi * t_ / t_[-1]))
    df = pd.DataFrame(
        {
            "timestamp": t_,
            "yaw_rate_rad_s": np.full(n, v_ / r_),
            "roll_rate_rad_s": np.gradient(tri, dt_),
            "accel_x_ms2": np.zeros(n),
            "accel_y_ms2": np.full(n, v_**2 / r_),
            "accel_z_ms2": np.zeros(n),
        }
    )
    T_ = float(t_[-1] - t_[0])
    assert np.isclose(radicality(df), (v_ / r_ * T_) ** 2 / T_, rtol=1e-3), (
        "constant-radius turn must give Ra = (V*T/R)^2 / T"
    )

    # Regression: one exact zero in the roll rate must not collapse the window.
    # np.sign made a single crossing look like two, shrinking t1-t0 to one sample.
    assert radicality(df) > 0.1, "zero-crossing detection collapsed the turn window"

    # Lift must rise with speed and equilibrium must reproduce it.
    polar = load_polar()
    assert polar.lift(10.0, 0.0) > polar.lift(5.0, 0.0)
    v_eq = equilibrium_speed(polar, 81.741)
    assert np.isclose(float(polar.lift(v_eq, 0.0)), 81.741 * G, rtol=1e-4)
    print("self-check: OK")


if __name__ == "__main__":
    _self_check()
    polar = load_polar()
    print(f"reference speed      : {polar.v_ref:.4f} m/s")
    print(f"roll cases (rad)     : {np.round(polar.roll_rad, 4)}")
    for m in (65.0, 80.0, 95.0):
        print(f"equilibrium speed    : {m:5.1f} kg surfer -> {equilibrium_speed(polar, m + 1.741):.2f} m/s")

    df = simulate(polar)
    # Computed, not extracted - it lives in the computed-data view.
    out = BOARD_DIR / "computed-data" / "trajectory.csv"
    out.parent.mkdir(parents=True, exist_ok=True)
    df.to_csv(out, index=False, encoding="utf-8")
    print(f"\nwrote {out}  ({len(df)} rows @ 100 Hz)")
    print(f"  speed        {df.speed_ms.min():.2f} - {df.speed_ms.max():.2f} m/s")
    print(f"  turn radius  {df.turn_radius_m.min():.2f} - {df.turn_radius_m.max():.2f} m")
    print(f"  yaw rate     {df.yaw_rate_rad_s.min():.3f} - {df.yaw_rate_rad_s.max():.3f} rad/s")
    print(f"\n  Board-Jerk J = {board_jerk(df):.4g}   (dimensionless)")
    print(f"  Radicality Ra = {radicality(df):.4f} rad^2/s")
