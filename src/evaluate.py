"""Leave-one-board-out evaluation, reported as a distribution rather than a mean.

Reporting discipline
--------------------
Three rules here exist because breaking any of them produces a number that looks
good and means nothing.

**Spread, not just the mean.** With 13 hulls, one fold is 7.7 % of the evidence. The
corpus contains a 130.7 L paddleboard against a 24-59 L cluster; when it is the
held-out board there is nothing to interpolate from and the fold score can be
strongly negative. A mean alone hides that, so :func:`summarise` reports median,
min, max and the count of folds worse than the mean baseline.

**Relative error alongside absolute.** ``drag_rail_n`` spans -5,540 to +15,951 N
while ``lift_total_n`` reaches 894,599 N. An RMSE in newtons ranks models almost
entirely by how well they fit lift, so a model can win on newtons while being
useless on the rail term.

**R-squared is computed per fold, against that fold's own mean.** Pooling
predictions across folds and scoring once would let between-board variance inflate
the result -- the model would be rewarded for knowing that a paddleboard drags more
than a shortboard, which is the one thing a grouped split is meant to withhold.
"""

from __future__ import annotations

import numpy as np
import pandas as pd
from sklearn.metrics import mean_absolute_error, mean_squared_error, r2_score

from src.data import FEATURES, TARGETS
from src.models import CONDITION_ONLY, ESTIMATORS
from src.splits import leave_one_group_out

__all__ = ["evaluate_all", "fold_scores", "nested_lobo", "pooled_score", "summarise"]


def _metrics(y_true: np.ndarray, y_pred: np.ndarray) -> dict[str, float]:
    """MAE, RMSE, R-squared and a scale-free relative error, in newtons."""
    y_true = np.asarray(y_true, dtype=float)
    y_pred = np.asarray(y_pred, dtype=float)
    denominator = np.abs(y_true).mean()
    return {
        "mae_n": float(mean_absolute_error(y_true, y_pred)),
        "rmse_n": float(np.sqrt(mean_squared_error(y_true, y_pred))),
        "r2": float(r2_score(y_true, y_pred)) if y_true.size > 1 else float("nan"),
        # Mean absolute error as a fraction of mean |target|. Chosen over MAPE,
        # which is undefined on the 113 rows where drag_rail_n is exactly zero.
        "rel_mae": float(mean_absolute_error(y_true, y_pred) / denominator)
        if denominator > 0 else float("nan"),
    }


def fold_scores(
    table: pd.DataFrame,
    target: str,
    estimator_name: str,
    features: list[str] | None = None,
    level: str = "family",
) -> pd.DataFrame:
    """Leave-one-group-out scores for one estimator on one target.

    Parameters
    ----------
    table : pandas.DataFrame
        Training table from :func:`src.data.build_training_table`.
    target : str
        Column to predict, one of :data:`src.data.TARGETS`.
    estimator_name : str
        Key into :data:`src.models.ESTIMATORS`.
    features : list of str, optional
        Feature columns. Defaults to :data:`src.data.FEATURES`. Pass
        :data:`src.models.CONDITION_ONLY` for the no-geometry ablation.
    level : {'family', 'board'}, optional
        Grouping level for the held-out folds.

    Returns
    -------
    pandas.DataFrame
        One row per fold: ``held_out``, ``n_test``, and the metrics from
        :func:`_metrics`.

    Raises
    ------
    KeyError
        If ``estimator_name`` is unknown or ``target`` is not a column.
    """
    if estimator_name not in ESTIMATORS:
        raise KeyError(f"unknown estimator {estimator_name!r}; have {sorted(ESTIMATORS)}")
    if target not in table.columns:
        raise KeyError(f"target {target!r} not in table")

    columns = list(features) if features is not None else list(FEATURES)
    rows = []
    for held_out, train, test in leave_one_group_out(table, level=level):
        model = ESTIMATORS[estimator_name]()
        model.fit(train[columns].to_numpy(float), train[target].to_numpy(float))
        predicted = model.predict(test[columns].to_numpy(float))
        rows.append({"held_out": held_out, "n_test": len(test),
                     **_metrics(test[target].to_numpy(float), predicted)})
    return pd.DataFrame(rows)


def pooled_score(
    table: pd.DataFrame,
    target: str,
    estimator_name: str,
    features: list[str] | None = None,
    level: str = "family",
) -> dict[str, float]:
    """R-squared over all held-out predictions concatenated, not averaged per fold.

    Reported **beside** the per-fold figure, never instead of it, because the two
    differ enormously and the difference is a property of the metric rather than of
    the model. Measured on this corpus with 5-NN on ``drag_total_n``: per-fold
    median R-squared is -0.485 while the pooled value is +0.193 and the pooled
    signed-log value is +0.284. Same model, same folds, same predictions.

    The gap is the between-board variance. Pooling puts it in the denominator, so
    the model is credited for knowing that a 130.7 L paddleboard drags more than a
    24 L shortboard -- which is the one thing a board-grouped split exists to
    withhold. Pooling is not wrong, but it answers "can it rank hulls?", not "can it
    predict forces on a hull it has never seen?".

    This is also how the corpus's earlier 5-NN baseline reached mean R-squared
    +0.52: pooled, in log space. Reproduced here at +0.525 on ``drag_friction_n``.

    Parameters
    ----------
    table : pandas.DataFrame
        Training table.
    target : str
        Column to predict.
    estimator_name : str
        Key into :data:`src.models.ESTIMATORS`.
    features : list of str, optional
        Feature columns; defaults to :data:`src.data.FEATURES`.
    level : {'family', 'board'}, optional
        Grouping level.

    Returns
    -------
    dict
        ``pooled_r2`` in newtons and ``pooled_r2_log`` in signed-log space.
    """
    columns = list(features) if features is not None else list(FEATURES)
    from src.models import signed_log  # local import: avoids a circular import

    observed, predicted = [], []
    for _, train, test in leave_one_group_out(table, level=level):
        model = ESTIMATORS[estimator_name]()
        model.fit(train[columns].to_numpy(float), train[target].to_numpy(float))
        predicted.append(model.predict(test[columns].to_numpy(float)))
        observed.append(test[target].to_numpy(float))
    y = np.concatenate(observed)
    p = np.concatenate(predicted)
    return {
        "pooled_r2": float(r2_score(y, p)),
        "pooled_r2_log": float(r2_score(signed_log(y), signed_log(p))),
    }


def summarise(scores: pd.DataFrame) -> dict[str, float]:
    """Collapse per-fold scores, keeping the spread visible.

    Parameters
    ----------
    scores : pandas.DataFrame
        Output of :func:`fold_scores`.

    Returns
    -------
    dict
        ``r2_mean``, ``r2_median``, ``r2_min``, ``r2_max``, ``rel_mae_median``,
        ``mae_n_median`` and ``n_folds_negative_r2`` -- the count of hulls the model
        predicted worse than that fold's own mean.
    """
    return {
        "r2_mean": float(scores["r2"].mean()),
        "r2_median": float(scores["r2"].median()),
        "r2_min": float(scores["r2"].min()),
        "r2_max": float(scores["r2"].max()),
        "rel_mae_median": float(scores["rel_mae"].median()),
        "mae_n_median": float(scores["mae_n"].median()),
        "n_folds_negative_r2": int((scores["r2"] < 0).sum()),
        "n_folds": int(len(scores)),
    }


def evaluate_all(
    table: pd.DataFrame,
    targets: list[str] | None = None,
    level: str = "family",
) -> pd.DataFrame:
    """Every estimator against every target, with and without geometry.

    Parameters
    ----------
    table : pandas.DataFrame
        Training table.
    targets : list of str, optional
        Defaults to :data:`src.data.TARGETS`.
    level : {'family', 'board'}, optional
        Grouping level.

    Returns
    -------
    pandas.DataFrame
        One row per (target, estimator, feature set) with the summary statistics.
        ``feature_set`` is ``'full'`` or ``'condition_only'``; the difference
        between them on a given target is the measured value of the geometry axis.
    """
    targets = list(targets) if targets is not None else list(TARGETS)
    rows = []
    for target in targets:
        for name in ESTIMATORS:
            for label, columns in (("full", FEATURES), ("condition_only", CONDITION_ONLY)):
                scores = fold_scores(table, target, name, features=columns, level=level)
                pooled = pooled_score(table, target, name, features=columns, level=level)
                rows.append({"target": target, "estimator": name, "feature_set": label,
                             **summarise(scores), **pooled})
    return pd.DataFrame(rows)


# Grid searched inside each training fold. Deliberately small: with 12 training
# boards per outer fold, a larger grid buys optimism, not accuracy.
SVR_GRID: list[dict] = [
    {"C": c, "epsilon": e, "gamma": g}
    for c in (1.0, 10.0, 100.0)
    for e in (0.01, 0.05, 0.2)
    for g in ("scale", 0.1, 1.0)
]


def nested_lobo(
    table: pd.DataFrame,
    target: str,
    grid: list[dict] | None = None,
    level: str = "family",
) -> pd.DataFrame:
    """Nested leave-one-board-out: tune inside the fold, score outside it.

    Hyperparameters are selected by an inner grouped CV over the **training boards
    only**. The held-out board is never seen during selection, so the resulting
    score is an honest estimate of performance on an unseen hull.

    This matters more than it usually does here. Measured on ``drag_friction_n``,
    the untuned SVR scores a median R-squared of **-0.265** while the best grid
    point scores **+0.556** -- but that +0.556 was chosen by looking at the same
    folds it is scored on, and is therefore optimistic by an unknown amount.
    Quoting it as a result would be selection leakage wearing a cross-validation
    costume. This function is what replaces it with a defensible number.

    Parameters
    ----------
    table : pandas.DataFrame
        Training table.
    target : str
        Column to predict.
    grid : list of dict, optional
        SVR keyword sets to search. Defaults to :data:`SVR_GRID`.
    level : {'family', 'board'}, optional
        Grouping level for both the outer and inner splits.

    Returns
    -------
    pandas.DataFrame
        One row per outer fold: ``held_out``, the selected ``C``/``epsilon``/
        ``gamma``, ``inner_r2`` (the winning inner score) and ``r2`` (the honest
        outer score in newtons).

    Notes
    -----
    Cost is ``outer_folds * len(grid) * inner_folds`` fits. With 13 boards and a
    27-point grid that is roughly 1,400 SVR fits, a couple of minutes.
    """
    from sklearn.svm import SVR

    from src.models import _wrap

    grid = list(grid) if grid is not None else list(SVR_GRID)
    rows = []
    for held_out, train, test in leave_one_group_out(table, level=level):
        best_score, best_params = -np.inf, grid[0]
        for params in grid:
            inner = []
            for _, inner_train, inner_test in leave_one_group_out(train, level=level):
                model = _wrap(SVR(kernel="rbf", **params))
                model.fit(inner_train[FEATURES].to_numpy(float),
                          inner_train[target].to_numpy(float))
                predicted = model.predict(inner_test[FEATURES].to_numpy(float))
                inner.append(r2_score(inner_test[target].to_numpy(float), predicted))
            # Median, not mean: one pathological inner board must not pick the
            # hyperparameters for all of them.
            score = float(np.median(inner))
            if score > best_score:
                best_score, best_params = score, params

        model = _wrap(SVR(kernel="rbf", **best_params))
        model.fit(train[FEATURES].to_numpy(float), train[target].to_numpy(float))
        predicted = model.predict(test[FEATURES].to_numpy(float))
        rows.append({
            "held_out": held_out, **best_params, "inner_r2": best_score,
            "r2": r2_score(test[target].to_numpy(float), predicted),
        })
    return pd.DataFrame(rows)
