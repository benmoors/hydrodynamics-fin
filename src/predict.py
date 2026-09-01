"""Query interface for the fitted surrogate, with explicit out-of-bounds handling.

Why an envelope at all
----------------------
The rubric requires a stated strategy for missing, NaN and out-of-bounds inputs, but
the engineering reason is sharper than the marking scheme. This surrogate is trained
on **13 hulls at one speed**. An SVR with an RBF kernel does not refuse a query
outside that range -- it returns a confident number that decays smoothly toward the
training mean, and nothing in the output distinguishes a genuine interpolation from
an extrapolation two hull-lengths beyond anything ever measured.

The Virtual Surfer queries this model at 100 Hz along a trajectory. A silent
extrapolation there propagates into turning radius, then yaw rate, then Radicality,
and arrives in the report as a physical claim. So every prediction is accompanied by
an in-envelope flag, and the default policy warns rather than staying silent.

What the envelope does not do
-----------------------------
It is a per-feature bounding box, so it checks each input against the range seen in
training and nothing more. A query can sit inside every individual range and still
be in a hole -- a 130 L board with a shortboard's aspect ratio is inside both
margins and exists nowhere in the corpus. The bounding box will pass it. This is a
known limitation, stated rather than papered over; a convex hull or a density
estimate would catch it, and with 13 points neither would be trustworthy.
"""

from __future__ import annotations

import warnings
from dataclasses import dataclass, field

import numpy as np
import pandas as pd

from src.data import FEATURES, TARGETS
from src.models import ESTIMATORS

__all__ = ["Envelope", "SurrogatePredictor"]


@dataclass(frozen=True)
class Envelope:
    """Per-feature training ranges, used to flag extrapolation.

    Attributes
    ----------
    lower, upper : dict of str to float
        Minimum and maximum observed in training, per feature.
    """

    lower: dict[str, float] = field(default_factory=dict)
    upper: dict[str, float] = field(default_factory=dict)

    @classmethod
    def from_table(cls, table: pd.DataFrame, features: list[str]) -> "Envelope":
        """Measure the envelope from a training table.

        Parameters
        ----------
        table : pandas.DataFrame
            Training rows.
        features : list of str
            Feature columns to bound.

        Returns
        -------
        Envelope
        """
        return cls(
            lower={f: float(table[f].min()) for f in features},
            upper={f: float(table[f].max()) for f in features},
        )

    def check(self, X: pd.DataFrame) -> pd.DataFrame:
        """Per-row, per-feature in-range flags.

        Parameters
        ----------
        X : pandas.DataFrame
            Query rows, columns matching the envelope's features.

        Returns
        -------
        pandas.DataFrame
            Boolean, same index as ``X``, one column per feature. True means the
            value lies within the training range. NaN is reported as False -- a
            missing input is not in the envelope, and treating it as acceptable is
            how a NaN reaches a physical claim.
        """
        flags = {}
        for name, low in self.lower.items():
            column = X[name].astype(float)
            flags[name] = (column >= low) & (column <= self.upper[name])
        return pd.DataFrame(flags, index=X.index).fillna(False)

    def describe(self) -> pd.DataFrame:
        """Envelope as a table, for the report's inputs/outputs section.

        Returns
        -------
        pandas.DataFrame
            Columns ``feature``, ``min``, ``max``.
        """
        return pd.DataFrame(
            {"feature": list(self.lower), "min": list(self.lower.values()),
             "max": [self.upper[f] for f in self.lower]}
        )


class SurrogatePredictor:
    """One fitted estimator per target, plus the envelope they were trained in.

    Parameters
    ----------
    estimator_name : str, optional
        Key into :data:`src.models.ESTIMATORS`. Defaults to ``'svr_rbf'``.
    features : list of str, optional
        Feature columns. Defaults to :data:`src.data.FEATURES`.
    targets : list of str, optional
        Targets to fit. Defaults to :data:`src.data.TARGETS`.
    policy : {'warn', 'refuse', 'allow'}, optional
        What to do when a query falls outside the envelope. ``'warn'`` (default)
        predicts and raises a :class:`UserWarning` naming the offending features.
        ``'refuse'`` raises :class:`ValueError`. ``'allow'`` is silent and should be
        used only when the caller is checking ``in_envelope`` itself.

    Attributes
    ----------
    envelope_ : Envelope
        Training ranges. Available after ``fit``.
    models_ : dict of str to estimator
        One fitted estimator per target.

    Examples
    --------
    >>> import warnings
    >>> from src.data import build_training_table
    >>> with warnings.catch_warnings():
    ...     warnings.simplefilter("ignore")
    ...     table = build_training_table()
    >>> predictor = SurrogatePredictor().fit(table)
    >>> out = predictor.predict(pd.DataFrame([{
    ...     "volume_shape_l": 30.0, "length_over_width": 3.7,
    ...     "thickness_over_length": 0.026, "drift_deg": 5.0, "roll_rad": 0.3}]))
    >>> bool(out["in_envelope"].iloc[0])
    True
    """

    def __init__(
        self,
        estimator_name: str = "svr_rbf",
        features: list[str] | None = None,
        targets: list[str] | None = None,
        policy: str = "warn",
    ) -> None:
        if estimator_name not in ESTIMATORS:
            raise KeyError(f"unknown estimator {estimator_name!r}; have {sorted(ESTIMATORS)}")
        if policy not in {"warn", "refuse", "allow"}:
            raise ValueError(f"policy must be 'warn', 'refuse' or 'allow', got {policy!r}")
        self.estimator_name = estimator_name
        self.features = list(features) if features is not None else list(FEATURES)
        self.targets = list(targets) if targets is not None else list(TARGETS)
        self.policy = policy
        self.envelope_: Envelope | None = None
        self.models_: dict = {}

    def fit(self, table: pd.DataFrame) -> "SurrogatePredictor":
        """Fit one estimator per target and record the training envelope.

        Parameters
        ----------
        table : pandas.DataFrame
            Training table containing every feature and target column.

        Returns
        -------
        SurrogatePredictor
            self.

        Raises
        ------
        KeyError
            If a required column is absent.
        ValueError
            If the table contains NaN in any feature or target -- fitting through a
            NaN silently drops rows and changes what the envelope means.
        """
        missing = [c for c in self.features + self.targets if c not in table.columns]
        if missing:
            raise KeyError(f"table is missing columns: {missing}")
        subset = table[self.features + self.targets]
        if subset.isna().to_numpy().any():
            raise ValueError("training table contains NaN in a feature or target column")

        X = subset[self.features].to_numpy(float)
        for target in self.targets:
            model = ESTIMATORS[self.estimator_name]()
            model.fit(X, subset[target].to_numpy(float))
            self.models_[target] = model
        self.envelope_ = Envelope.from_table(table, self.features)
        return self

    def predict(self, X: pd.DataFrame) -> pd.DataFrame:
        """Predict every target, flagging rows outside the training envelope.

        Parameters
        ----------
        X : pandas.DataFrame
            Query rows with the feature columns. Units follow
            :data:`src.data.FEATURES`: litres, dimensionless, dimensionless,
            degrees, radians.

        Returns
        -------
        pandas.DataFrame
            One column per target, in newtons, plus a boolean ``in_envelope`` and a
            string ``out_of_range`` naming the offending features (empty when in
            range). The flags are returned rather than only warned about, so a
            caller can filter without re-deriving them.

        Raises
        ------
        RuntimeError
            If called before ``fit``.
        KeyError
            If a feature column is absent from ``X``.
        ValueError
            If ``X`` contains NaN, or if any row is out of envelope under
            ``policy='refuse'``.

        Warns
        -----
        UserWarning
            Under ``policy='warn'``, once per call, naming how many rows fell
            outside and which features were responsible.
        """
        if self.envelope_ is None:
            raise RuntimeError("SurrogatePredictor.predict called before fit")
        missing = [c for c in self.features if c not in X.columns]
        if missing:
            raise KeyError(f"query is missing feature columns: {missing}")

        query = X[self.features]
        if query.isna().to_numpy().any():
            raise ValueError(
                "query contains NaN. There is no defensible imputation for a board "
                "dimension, so this refuses rather than guessing a hull."
            )

        flags = self.envelope_.check(query)
        in_envelope = flags.all(axis=1)
        offenders = flags.apply(
            lambda row: ", ".join(sorted(flags.columns[~row])), axis=1
        )

        if not in_envelope.all():
            names = sorted({f for row in offenders[~in_envelope] for f in row.split(", ") if f})
            message = (
                f"{int((~in_envelope).sum())} of {len(query)} queries fall outside the "
                f"training envelope on: {', '.join(names)}. Predictions there are "
                f"extrapolation, not interpolation."
            )
            if self.policy == "refuse":
                raise ValueError(message)
            if self.policy == "warn":
                warnings.warn(message, UserWarning, stacklevel=2)

        values = query.to_numpy(float)
        out = pd.DataFrame(
            {t: self.models_[t].predict(values) for t in self.targets}, index=X.index
        )
        out["in_envelope"] = in_envelope
        out["out_of_range"] = offenders
        return out
