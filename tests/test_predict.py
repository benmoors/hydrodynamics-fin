"""Envelope and input-handling tests for the query API.

The rubric asks for an explicit strategy on missing, NaN and out-of-bounds inputs.
These tests pin that strategy, because the failure they guard against is silent: an
RBF kernel answers an absurd query with a confident number and nothing in the return
value distinguishes it from an interpolation.
"""

from __future__ import annotations

import warnings

import numpy as np
import pandas as pd
import pytest

from src.data import FEATURES, TARGETS, build_training_table
from src.predict import Envelope, SurrogatePredictor


@pytest.fixture(scope="module")
def table() -> pd.DataFrame:
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", UserWarning)
        return build_training_table()


@pytest.fixture(scope="module")
def fitted(table) -> SurrogatePredictor:
    # knn5 rather than svr_rbf: same interface, far cheaper to fit 5 times per fixture.
    return SurrogatePredictor(estimator_name="knn5").fit(table)


def _query(**overrides) -> pd.DataFrame:
    row = {
        "volume_shape_l": 40.0, "length_over_width": 3.7,
        "thickness_over_length": 0.026, "drift_deg": 5.0, "roll_rad": 0.3,
    }
    row.update(overrides)
    return pd.DataFrame([row])


class TestEnvelope:
    def test_measures_the_training_range(self, table):
        envelope = Envelope.from_table(table, FEATURES)
        for feature in FEATURES:
            assert envelope.lower[feature] == pytest.approx(table[feature].min())
            assert envelope.upper[feature] == pytest.approx(table[feature].max())

    def test_boundary_values_are_inside(self, table):
        """A query exactly at the training minimum is interpolation, not extrapolation."""
        envelope = Envelope.from_table(table, FEATURES)
        edge = pd.DataFrame([{f: envelope.lower[f] for f in FEATURES}])
        assert bool(envelope.check(edge).all(axis=1).iloc[0])

    def test_nan_is_reported_out_of_envelope(self, table):
        """A missing input is not in the envelope. Treating NaN as acceptable is how a
        NaN reaches a physical claim."""
        envelope = Envelope.from_table(table, FEATURES)
        row = pd.DataFrame([{f: np.nan for f in FEATURES}])
        assert not bool(envelope.check(row).any(axis=1).iloc[0])

    def test_describe_lists_every_feature(self, table):
        described = Envelope.from_table(table, FEATURES).describe()
        assert set(described["feature"]) == set(FEATURES)
        assert (described["max"] >= described["min"]).all()


class TestFit:
    def test_fits_one_model_per_target(self, fitted):
        assert set(fitted.models_) == set(TARGETS)

    def test_rejects_a_table_missing_columns(self, table):
        with pytest.raises(KeyError, match="missing columns"):
            SurrogatePredictor().fit(table.drop(columns=["roll_rad"]))

    def test_rejects_nan_in_training(self, table):
        """Fitting through a NaN silently drops rows and changes what the envelope means."""
        poisoned = table.copy()
        poisoned.loc[poisoned.index[0], "volume_shape_l"] = np.nan
        with pytest.raises(ValueError, match="contains NaN"):
            SurrogatePredictor().fit(poisoned)

    def test_unknown_estimator_refuses_at_construction(self):
        with pytest.raises(KeyError, match="unknown estimator"):
            SurrogatePredictor(estimator_name="magic")

    def test_unknown_policy_refuses_at_construction(self):
        with pytest.raises(ValueError, match="policy must be"):
            SurrogatePredictor(policy="shrug")


class TestPredict:
    def test_in_envelope_query_is_silent(self, fitted):
        with warnings.catch_warnings():
            warnings.simplefilter("error")  # any warning becomes a failure
            out = fitted.predict(_query())
        assert bool(out["in_envelope"].iloc[0])
        assert out["out_of_range"].iloc[0] == ""

    def test_returns_every_target(self, fitted):
        out = fitted.predict(_query())
        for target in TARGETS:
            assert target in out.columns
            assert np.isfinite(out[target].iloc[0])

    def test_out_of_envelope_warns_and_names_the_feature(self, fitted):
        with pytest.warns(UserWarning, match="volume_shape_l"):
            out = fitted.predict(_query(volume_shape_l=500.0))
        assert not bool(out["in_envelope"].iloc[0])
        assert "volume_shape_l" in out["out_of_range"].iloc[0]

    def test_names_every_offending_feature_not_just_the_first(self, fitted):
        with pytest.warns(UserWarning):
            out = fitted.predict(_query(volume_shape_l=500.0, length_over_width=99.0))
        offenders = out["out_of_range"].iloc[0]
        assert "volume_shape_l" in offenders
        assert "length_over_width" in offenders

    def test_refuse_policy_raises(self, table):
        model = SurrogatePredictor(estimator_name="knn5", policy="refuse").fit(table)
        with pytest.raises(ValueError, match="outside the training envelope"):
            model.predict(_query(volume_shape_l=500.0))

    def test_allow_policy_is_silent_but_still_flags(self, table):
        """'allow' suppresses the warning, never the flag. A caller opting out of the
        noise must still be able to see what happened."""
        model = SurrogatePredictor(estimator_name="knn5", policy="allow").fit(table)
        with warnings.catch_warnings():
            warnings.simplefilter("error")
            out = model.predict(_query(volume_shape_l=500.0))
        assert not bool(out["in_envelope"].iloc[0])

    def test_nan_query_refuses(self, fitted):
        """There is no defensible imputation for a board dimension."""
        with pytest.raises(ValueError, match="contains NaN"):
            fitted.predict(_query(volume_shape_l=np.nan))

    def test_missing_column_refuses(self, fitted):
        with pytest.raises(KeyError, match="missing feature columns"):
            fitted.predict(_query().drop(columns=["drift_deg"]))

    def test_predict_before_fit_refuses(self):
        with pytest.raises(RuntimeError, match="before fit"):
            SurrogatePredictor().predict(_query())

    def test_mixed_batch_flags_only_the_bad_row(self, fitted):
        batch = pd.concat([_query(), _query(volume_shape_l=500.0)], ignore_index=True)
        with pytest.warns(UserWarning, match="1 of 2"):
            out = fitted.predict(batch)
        assert out["in_envelope"].tolist() == [True, False]

    def test_preserves_the_caller_index(self, fitted):
        batch = _query()
        batch.index = pd.Index([42])
        assert fitted.predict(batch).index.tolist() == [42]


class TestKnownLimitation:
    def test_bounding_box_passes_a_physically_absent_combination(self, fitted, table):
        """Documented limitation, asserted so it cannot be quietly forgotten.

        The envelope is a per-feature box, so a 130 L hull with a 24 L shortboard's
        aspect ratio and thickness sits inside every individual margin while existing
        nowhere in the corpus. The check passes it. A convex hull would catch this;
        with 13 boards a convex hull would not be trustworthy either.

        If this test ever starts failing, the envelope has become stricter than
        documented and the docstring in src/predict.py needs updating with it.
        """
        shortboard = table.loc[table["volume_shape_l"].idxmin()]
        chimera = _query(
            volume_shape_l=float(table["volume_shape_l"].max()),
            length_over_width=float(shortboard["length_over_width"]),
            thickness_over_length=float(shortboard["thickness_over_length"]),
        )
        with warnings.catch_warnings():
            warnings.simplefilter("error")
            out = fitted.predict(chimera)
        assert bool(out["in_envelope"].iloc[0])
