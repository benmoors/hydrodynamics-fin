"""Gate B rerun: the live-solver feasibility screen with F_f(V) in place of SWD's friction_n.

FEASIBILITY SCREEN ONLY, like the screen it re-runs (SWD/model/identifiability_screen_live.py); nothing here is the
project's forward model. The screen is imported unchanged and run end to end, with three of its module-level names
replaced before main() looks them up:

    load_forces   friction_n at the screen's attitude becomes F_f(V), at the same converged speeds, so the screen's
                  own PCHIP of it, and drag_poly, are unchanged
    select        the attitude and V0 are held at the original run's (read from its summary.csv), so friction is the
                  only change; the candidates file lists that one attitude
    OUT_DIR       identifiability_screen_live_ff/, beside the original, which is not written

PLANTED and FRICTION_SHIFT keep their values but now scale F_f, not SWD's friction_n. No verdict is given.

Reading the outputs: three of them mix F_f with SWD-only quantities.
    forces_used.csv          friction_n is F_f, 0.07 N (2 m/s) to 1.07 N (10 m/s) below SWD's own, beside SWD's
                             drag_total_n; that total already missed SWD's components by 0.9-1.4 N (within the
                             screen's 1 % check), and with F_f it misses them by 0.002-1.4 N. The runs use
                             friction + planing + rail, never drag_total_n
    attitude_candidates.csv  v_eq_swd_total_k1 is still from SWD's total drag
    v0_search.csv            the screen's V0 rule under F_f; it would pick 4.4 m/s, but V0 is held at 8.3 m/s

Run
---
    python friction-function/rerun_live_screen_ff.py
"""

import sys
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
for folder in (ROOT / "SWD" / "model", Path(__file__).resolve().parent):
    if str(folder) not in sys.path:
        sys.path.insert(0, str(folder))

import friction_force as ff  # noqa: E402
import identifiability_screen_live as screen  # noqa: E402

ORIGINAL_DIR = screen.OUT_DIR
OUT_DIR = ORIGINAL_DIR.with_name("identifiability_screen_live_ff")


def original_choice():
    """The attitude and V0 the original run chose, from its summary.csv.

    Returns
    -------
    tuple of float
        ``(pos_y, pos_x, v0)``.
    """
    summary = pd.read_csv(ORIGINAL_DIR / "summary.csv").set_index("metric")["value"]
    return float(summary["attitude_pos_y"]), float(summary["attitude_pos_x"]), float(summary["v0_ms"])


POS_Y, POS_X, V0 = original_choice()
if (POS_Y, POS_X) != (ff.POS_Y, ff.POS_X):
    raise RuntimeError(f"the original attitude ({POS_Y}, {POS_X}) is not friction_force's ({ff.POS_Y}, {ff.POS_X})")
original_load_forces = screen.load_forces


def load_forces_ff(path=screen.SOLVER_CSV):
    """The screen's load_forces, with friction_n at the held attitude replaced by F_f(V).

    The decomposition check (step 1) runs first, on SWD's own friction, so the same rows are kept as in the original.

    Parameters
    ----------
    path : pathlib.Path
        ``converged/solver_points.csv``.

    Returns
    -------
    kept : pandas.DataFrame
        The kept rows; at the held attitude ``friction_n`` is F_f, N.
    n_dropped : int
        Rows dropped by the decomposition check.
    """
    df, n_dropped = original_load_forces(path)
    at = (df.pos_y == POS_Y) & (df.pos_x == POS_X)
    A, L = ff.wetted_geometry(path, POS_Y, POS_X)
    df = df.copy()
    df.loc[at, "friction_n"] = ff.F_f(df.loc[at, "speed_ms"].to_numpy(dtype=float), A, L)
    return df, n_dropped


def select_held(df, t_end):
    """The original attitude and V0, in the shape the screen's select() returns.

    Parameters
    ----------
    df : pandas.DataFrame
        Output of load_forces_ff().
    t_end : float
        mmc1's span, s; used only for the V0 table, which is written for comparison.

    Returns
    -------
    dict
        ``candidates`` (the held attitude only), ``forces``, ``v0``, ``rank`` (0) and ``v0_table``.
    """
    ranked = screen.rank_attitudes(df)
    row = ranked[(ranked.pos_y == POS_Y) & (ranked.pos_x == POS_X)]
    forces = screen.Forces.at(df, POS_Y, POS_X, float(row.v_lo.iloc[0]), float(row.v_hi.iloc[0]))
    _, v0_table = screen.choose_v0(forces, t_end)
    return dict(candidates=row.reset_index(drop=True), forces=forces, v0=V0, rank=0, v0_table=v0_table)


def main():
    """Run the screen with F_f and print its Monte Carlo spread of k beside the original's."""
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    print("=== Gate B rerun: friction is F_f(V), not SWD's friction_n (FEASIBILITY ONLY) ===")
    print(f"Attitude pos_y {POS_Y:g}, pos_x {POS_X:g} and V0 = {V0:g} m/s are held at the original run's. "
          f"PLANTED = {screen.PLANTED} and FRICTION_SHIFT = {screen.FRICTION_SHIFT} now scale F_f, not friction_n.\n")
    screen.load_forces, screen.select, screen.OUT_DIR = load_forces_ff, select_held, OUT_DIR
    screen.main()

    keys = ["duration_s", "sigma", "set"]
    columns = keys + ["N", "mean k", "sd k", "within ±band", "converged"]
    original = pd.read_csv(ORIGINAL_DIR / "monte_carlo_summary.csv")
    rerun = pd.read_csv(OUT_DIR / "monte_carlo_summary.csv")
    this = "this screen: one attitude, trimmed lift (a_x only)"
    both = original[original.screen == this][columns].merge(rerun[rerun.screen == this][columns], on=keys,
                                                            suffixes=(" (SWD friction_n)", " (F_f)"))
    print("\nMonte Carlo spread of k, SWD's friction_n against F_f (each relative to its own friction):")
    print(both.to_string(index=False, float_format=lambda v: f"{v:.5g}"))


if __name__ == "__main__":
    main()
