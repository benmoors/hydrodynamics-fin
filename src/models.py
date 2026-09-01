"""Surrogate models and the baselines they must beat.

Four estimators, deliberately different in kind rather than four flavours of one
idea. The rubric asks for at least one credible alternative; comparing an SVR to a
slightly different SVR would satisfy the letter and none of the point.

===================  =========================================================
Estimator            What it establishes
===================  =========================================================
:func:`make_svr`     The primary surrogate. RBF kernel in a StandardScaler
                     pipeline, as the unit's Week 5 material specifies.
:func:`make_tree`    A structurally different learner: axis-aligned partitions,
                     no distance metric, no scaling sensitivity. If it wins, the
                     response is closer to piecewise-constant than smooth.
:func:`make_knn`     The 5-NN baseline already run on this corpus, which scored
                     mean R-squared +0.52 under leave-3-boards-out. Reproduced
                     here so the comparison is like-for-like rather than quoted
                     from an earlier session.
:func:`make_mean`    Predicts the training mean. The floor. Any model that fails
                     to beat this has learned nothing, and on grouped splits that
                     is a real possibility rather than a formality.
===================  =========================================================

The signed-log target transform
-------------------------------
Targets span more than three orders of magnitude -- 157 N to 522 kN for total drag
-- so an unscaled squared-error fit is dominated entirely by the largest hulls at
the widest drift angles. A log transform fixes that, but ``drag_rail_n`` is
**negative on 33 rows** (the rail generating thrust) and exactly zero on 113 more,
so ``log`` and ``log1p`` both fail on it.

:func:`signed_log` is used instead: ``sign(y) * log1p(|y|)``. It is smooth,
strictly increasing, exactly invertible, maps 0 to 0, and preserves sign -- so a
predicted thrust stays a thrust. Errors are reported in newtons after inverting,
never in log units, because a log-space RMSE is not a force.
"""

from __future__ import annotations

import numpy as np
from sklearn.compose import TransformedTargetRegressor
from sklearn.dummy import DummyRegressor
from sklearn.neighbors import KNeighborsRegressor
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler
from sklearn.svm import SVR
from sklearn.tree import DecisionTreeRegressor

__all__ = [
    "CONDITION_ONLY",
    "ESTIMATORS",
    "inverse_signed_log",
    "make_knn",
    "make_mean",
    "make_svr",
    "make_tree",
    "signed_log",
]

#: Features available to the condition-only ablation: no geometry at all. The gap
#: between this and the full model, measured on held-out boards, IS the value of the
#: geometry axis. If it is near zero, that is a finding to report, not a failure.
CONDITION_ONLY: list[str] = ["drift_deg", "roll_rad"]


def signed_log(y: np.ndarray) -> np.ndarray:
    """``sign(y) * log1p(|y|)``. Compresses range while preserving sign and zero.

    Parameters
    ----------
    y : array_like of float
        Forces in newtons. May be negative (rail thrust) or zero (rail disengaged).

    Returns
    -------
    numpy.ndarray
        Transformed values, same shape.
    """
    y = np.asarray(y, dtype=float)
    return np.sign(y) * np.log1p(np.abs(y))


def inverse_signed_log(z: np.ndarray) -> np.ndarray:
    """Exact inverse of :func:`signed_log`.

    Parameters
    ----------
    z : array_like of float
        Transformed values.

    Returns
    -------
    numpy.ndarray
        Forces in newtons.
    """
    z = np.asarray(z, dtype=float)
    return np.sign(z) * np.expm1(np.abs(z))


def _wrap(estimator, transform_target: bool = True):
    """Scale features, and optionally fit in signed-log target space."""
    pipe = Pipeline([("scale", StandardScaler()), ("model", estimator)])
    if not transform_target:
        return pipe
    return TransformedTargetRegressor(
        regressor=pipe, func=signed_log, inverse_func=inverse_signed_log,
    )


def make_svr(C: float = 10.0, epsilon: float = 0.05, gamma: float = 0.1):
    """Primary surrogate: StandardScaler + RBF SVR, fitted in signed-log space.

    Parameters
    ----------
    C : float, optional
        Regularisation. Higher fits the training data harder.
    epsilon : float, optional
        Width of the epsilon-insensitive tube, in signed-log units.
    gamma : float, optional
        RBF kernel coefficient. Nested CV chose 0.1 in 13 of 13 folds, in
        preference to scikit-learn's variance-adaptive ``'scale'``, which this
        function no longer defaults to. A string is still accepted by the
        underlying estimator if you want ``'scale'`` back.

    Returns
    -------
    sklearn.compose.TransformedTargetRegressor
        Single-output. SVR does not support multi-output, so one is fitted per
        target -- which is also what lets each target keep its own hyperparameters.

    Notes
    -----
    **The defaults matter more here than they usually do.** With scikit-learn's
    ``gamma='scale'`` and ``C=100`` this model scored a median leave-one-board-out
    R-squared of **-0.265** on ``drag_friction_n`` -- worse than predicting the mean,
    and worse than a decision tree left on its own defaults. That is a property of
    the defaults, not of the method: 339 of 389 training rows became support
    vectors, which is memorisation rather than regression.

    The values above are the modal selection from :func:`src.evaluate.nested_lobo`,
    which tunes inside each training fold and scores on the untouched held-out
    board. ``gamma=0.1`` was chosen in **13 of 13** folds. Under that procedure the
    honest score is **+0.521 median, 12 of 13 folds positive**.

    Do not quote the tuned score as if these defaults produced it. The reportable
    figure is the nested one, because it includes the cost of choosing. A grid
    searched against the held-out boards scored +0.556 -- only 0.035 higher, which
    is a pleasantly small leak, but it is still a leak and still not reportable.
    """
    return _wrap(SVR(kernel="rbf", C=C, epsilon=epsilon, gamma=gamma))


def make_tree(max_depth: int | None = 6, min_samples_leaf: int = 4, seed: int = 0):
    """Structural alternative: a single decision tree, natively multi-output.

    Parameters
    ----------
    max_depth : int or None, optional
        Depth cap. With only 13 independent hulls an unbounded tree memorises board
        identity from the geometry columns, so this is capped by default.
    min_samples_leaf : int, optional
        Minimum samples per leaf.
    seed : int, optional
        Random state, for reproducibility.

    Returns
    -------
    sklearn.compose.TransformedTargetRegressor
    """
    return _wrap(
        DecisionTreeRegressor(
            max_depth=max_depth, min_samples_leaf=min_samples_leaf, random_state=seed
        )
    )


def make_knn(n_neighbors: int = 5):
    """The 5-NN baseline previously run on this corpus.

    Parameters
    ----------
    n_neighbors : int, optional
        Neighbour count. 5 reproduces the earlier run.

    Returns
    -------
    sklearn.compose.TransformedTargetRegressor

    Notes
    -----
    With grouped splits every neighbour necessarily comes from a *different* hull,
    which is precisely why this is a fair baseline here and would not be under a
    random row split.
    """
    return _wrap(KNeighborsRegressor(n_neighbors=n_neighbors))


def make_mean():
    """Predict the training mean. The floor any model must clear.

    Returns
    -------
    sklearn.pipeline.Pipeline
        Not target-transformed: the mean of signed-log values back-transformed is
        not the mean force, and this baseline must stay trivially interpretable.
    """
    return _wrap(DummyRegressor(strategy="mean"), transform_target=False)


#: Named constructors, iterated by :mod:`src.evaluate`.
ESTIMATORS: dict[str, callable] = {
    "svr_rbf": make_svr,
    "decision_tree": make_tree,
    "knn5": make_knn,
    "mean_baseline": make_mean,
}
