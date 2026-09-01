"""Performance profiling and the speed/accuracy trade-off for the surrogate.

The engineering claim this project rests on is a speed claim: SWD takes 12 to 31
minutes to evaluate one board across 11 drift angles, and the surrogate answers in
microseconds. That claim is worth nothing unless it is measured, and it is worth
less than nothing if the accuracy it costs is not measured beside it.

This module measures three things.

**Where the time actually goes.** ``profile_pipeline`` runs cProfile over the whole
load-fit-predict path. The result is consistently unglamorous: the dominant cost is
reading CSVs, not fitting models, because the corpus is 389 rows. Reporting that
honestly matters more than finding a bottleneck worth optimising, because the
alternative -- optimising a 4 ms model fit -- is the textbook case of a real
complexity defect worth nothing.

**Arithmetic intensity.** ``arithmetic_intensity`` estimates FLOPs per byte for the
SVR prediction kernel, following the Week 2 roofline material. An RBF SVR evaluating
``n_sv`` support vectors over ``d`` features does roughly ``5*n_sv*d`` FLOPs against
``8*n_sv*d`` bytes of support-vector traffic, giving an intensity near 0.6 FLOP/byte
-- memory-bandwidth bound, like the centred-difference stencil in the unit's own
example. The practical consequence is that batching queries pays and micro-optimising
the arithmetic does not.

**The trade-off that actually matters.** ``tradeoff_table`` measures fit time, single
-query latency, batched throughput and held-out accuracy for every estimator, so the
choice between them is made on evidence rather than on which one sounds most modern.

Nothing here writes into ``SWD/data/``.
"""

from __future__ import annotations

import cProfile
import io
import pstats
import time
import warnings

import numpy as np
import pandas as pd

from src.data import FEATURES, build_training_table
from src.evaluate import fold_scores, summarise
from src.models import ESTIMATORS

__all__ = [
    "SWD_SECONDS_PER_BOARD",
    "arithmetic_intensity",
    "predict_latency",
    "profile_pipeline",
    "speedup_vs_swd",
    "tradeoff_table",
]

#: Measured SWD hydroscan cost for one board across 11 drift angles, in seconds.
#: Two runs, 2.7x apart, both at 20.000 m/s -- the spread is hull mesh size
#: (``n_elements`` 2 to 13), not speed. Quoted as a range because a single figure
#: would misrepresent it.
SWD_SECONDS_PER_BOARD: tuple[float, float] = (12 * 60.0, 31 * 60.0)


def profile_pipeline(sort_by: str = "cumulative", top: int = 15) -> str:
    """cProfile the full load, fit and predict path.

    Parameters
    ----------
    sort_by : str, optional
        A :class:`pstats.Stats` sort key. Defaults to ``'cumulative'``.
    top : int, optional
        Rows of the profile to return.

    Returns
    -------
    str
        The formatted profile table.
    """
    def run() -> None:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            table = build_training_table()
            X = table[FEATURES].to_numpy(float)
            y = table["drag_friction_n"].to_numpy(float)
            model = ESTIMATORS["svr_rbf"]()
            model.fit(X, y)
            model.predict(X)

    profiler = cProfile.Profile()
    profiler.enable()
    run()
    profiler.disable()

    buffer = io.StringIO()
    pstats.Stats(profiler, stream=buffer).sort_stats(sort_by).print_stats(top)
    return buffer.getvalue()


def arithmetic_intensity(
    n_support_vectors: int, n_features: int, bytes_per_float: int = 8
) -> dict[str, float]:
    """FLOPs per byte for one RBF-SVR prediction.

    An RBF kernel evaluation against one support vector costs, per feature, a
    subtract, a multiply and an add for the squared distance (3 FLOPs), plus a
    multiply-add for the dual-coefficient accumulation (2 FLOPs) -- about 5 FLOPs
    per support vector per feature. The memory traffic is the support-vector matrix
    itself, ``n_sv * d`` floats, which for any realistic model does not fit in L1
    and must be streamed.

    Parameters
    ----------
    n_support_vectors : int
        Support vectors in the fitted model. Must be > 0.
    n_features : int
        Feature count. Must be > 0.
    bytes_per_float : int, optional
        8 for float64, which is what scikit-learn uses here.

    Returns
    -------
    dict
        ``flops``, ``bytes``, ``intensity_flops_per_byte`` and ``bound``, where
        ``bound`` is ``'memory'`` below roughly 10 FLOP/byte and ``'compute'``
        above it.

    Raises
    ------
    ValueError
        If either dimension is non-positive.

    Examples
    --------
    >>> result = arithmetic_intensity(300, 5)
    >>> result["bound"]
    'memory'
    """
    if n_support_vectors <= 0 or n_features <= 0:
        raise ValueError("n_support_vectors and n_features must both be positive")
    flops = 5.0 * n_support_vectors * n_features
    traffic = float(bytes_per_float * n_support_vectors * n_features)
    intensity = flops / traffic
    return {
        "flops": flops,
        "bytes": traffic,
        "intensity_flops_per_byte": intensity,
        # The ridge of a typical desktop roofline sits near 10 FLOP/byte. Below it,
        # performance is set by bandwidth and vectorising the arithmetic buys little.
        "bound": "memory" if intensity < 10.0 else "compute",
    }


def predict_latency(
    model, X: np.ndarray, repeats: int = 7, batch: int = 1
) -> dict[str, float]:
    """Minimum-of-n prediction latency.

    Minimum rather than mean: the minimum is the least contaminated by scheduler
    noise on a desktop, which is the standard practice for microbenchmarks and the
    only defensible choice on a machine that is also running a browser.

    Parameters
    ----------
    model : fitted estimator
        Anything with ``predict``.
    X : numpy.ndarray
        Query rows to draw from.
    repeats : int, optional
        Timing repeats. The minimum is reported.
    batch : int, optional
        Rows per call.

    Returns
    -------
    dict
        ``batch``, ``seconds_per_call``, ``seconds_per_row``, ``rows_per_second``.
    """
    query = X[:batch] if batch <= len(X) else np.repeat(X, batch // len(X) + 1, axis=0)[:batch]
    model.predict(query)  # warm up: first call pays import and allocation costs
    best = min(
        (lambda t0: (model.predict(query), time.perf_counter() - t0)[1])(time.perf_counter())
        for _ in range(repeats)
    )
    return {
        "batch": float(batch),
        "seconds_per_call": best,
        "seconds_per_row": best / batch,
        "rows_per_second": batch / best if best > 0 else float("inf"),
    }


def speedup_vs_swd(seconds_per_row: float, rows_per_board: int = 55) -> dict[str, float]:
    """How much faster the surrogate is than an SWD hydroscan, per board.

    Parameters
    ----------
    seconds_per_row : float
        Surrogate latency per operating point.
    rows_per_board : int, optional
        Operating points per full scan: 11 drift angles x 5 roll cases = 55.

    Returns
    -------
    dict
        ``surrogate_seconds``, ``swd_seconds_low``, ``swd_seconds_high`` and the
        speedup factor at each end of SWD's measured range.
    """
    surrogate = seconds_per_row * rows_per_board
    low, high = SWD_SECONDS_PER_BOARD
    return {
        "surrogate_seconds": surrogate,
        "swd_seconds_low": low,
        "swd_seconds_high": high,
        "speedup_low": low / surrogate if surrogate > 0 else float("inf"),
        "speedup_high": high / surrogate if surrogate > 0 else float("inf"),
    }


def tradeoff_table(
    table: pd.DataFrame | None = None, target: str = "drag_friction_n"
) -> pd.DataFrame:
    """Fit cost, query latency and held-out accuracy for every estimator.

    Parameters
    ----------
    table : pandas.DataFrame, optional
        Training table. Built with defaults when omitted.
    target : str, optional
        Which target to score. Defaults to ``'drag_friction_n'`` -- the only one
        that generalises, so the only one where an accuracy comparison is meaningful.

    Returns
    -------
    pandas.DataFrame
        One row per estimator: ``fit_ms``, ``latency_us_single``,
        ``rows_per_second_batched``, ``r2_median``, ``n_folds_negative_r2``.
    """
    if table is None:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            table = build_training_table()

    X = table[FEATURES].to_numpy(float)
    y = table[target].to_numpy(float)

    rows = []
    for name, make in ESTIMATORS.items():
        model = make()
        start = time.perf_counter()
        model.fit(X, y)
        fit_seconds = time.perf_counter() - start

        single = predict_latency(model, X, batch=1)
        batched = predict_latency(model, X, batch=len(X))
        scores = summarise(fold_scores(table, target, name))

        rows.append({
            "estimator": name,
            "fit_ms": fit_seconds * 1e3,
            "latency_us_single": single["seconds_per_call"] * 1e6,
            "rows_per_second_batched": batched["rows_per_second"],
            "r2_median": scores["r2_median"],
            "n_folds_negative_r2": scores["n_folds_negative_r2"],
        })
    return pd.DataFrame(rows)


if __name__ == "__main__":  # pragma: no cover
    pd.set_option("display.width", 200)
    print("=" * 78)
    print("TRADE-OFF: accuracy against cost, target = drag_friction_n")
    print("=" * 78)
    trade = tradeoff_table()
    print(trade.to_string(index=False, float_format=lambda v: f"{v:12.3f}"))

    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        data = build_training_table()
    X = data[FEATURES].to_numpy(float)
    model = ESTIMATORS["svr_rbf"]()
    model.fit(X, data["drag_friction_n"].to_numpy(float))

    n_sv = int(model.regressor_.named_steps["model"].support_vectors_.shape[0])
    print(f"\nSupport vectors: {n_sv} of {len(X)} training rows")
    intensity = arithmetic_intensity(n_sv, len(FEATURES))
    print(f"Arithmetic intensity: {intensity['intensity_flops_per_byte']:.3f} FLOP/byte "
          f"({intensity['flops']:.0f} FLOPs / {intensity['bytes']:.0f} B) -> "
          f"{intensity['bound']}-bound")

    single = predict_latency(model, X, batch=1)
    batched = predict_latency(model, X, batch=len(X))
    print(f"\nLatency  single query : {single['seconds_per_call']*1e6:9.1f} us")
    print(f"Latency  batched       : {batched['seconds_per_row']*1e6:9.3f} us/row "
          f"({batched['rows_per_second']:,.0f} rows/s)")
    print(f"Batching gain          : {single['seconds_per_row']/batched['seconds_per_row']:9.1f}x")

    speed = speedup_vs_swd(batched["seconds_per_row"])
    print(f"\nOne board (55 operating points):")
    print(f"  surrogate : {speed['surrogate_seconds']*1e3:.3f} ms")
    print(f"  SWD       : {speed['swd_seconds_low']/60:.0f} to {speed['swd_seconds_high']/60:.0f} min")
    print(f"  speedup   : {speed['speedup_low']:,.0f}x to {speed['speedup_high']:,.0f}x")

    print("\n" + "=" * 78)
    print("WHERE THE TIME GOES (cProfile, cumulative)")
    print("=" * 78)
    print(profile_pipeline(top=12))
