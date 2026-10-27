"""Negative tests for the input checks added in SQA round 1 (2026-10-28), one per refused input, each with match=.

agy and Devin found each of these inputs passing silently, or failing with an unrelated error, before the check.
"""

from __future__ import annotations

import numpy as np
import pandas as pd
import pytest

from src import evaluate, geometry, physics_baseline as pb, profiling, splits
from src.data import build_training_table
from src.forward_model import forward_model as fm
from src.friction import friction_force as ff
from src.friction.blasius_shooting import blasius_thickness as bt
from src.friction.blasius_shooting import fd_blasius as fd
from src.friction.blasius_shooting import skin_and_shear as ss
from src.predict import SurrogatePredictor
from src.swd_model import identifiability_screen as ids

NAN, INF = float("nan"), float("inf")


# geometry: a reversed span was flipped by abs(), and a NaN passed every `<= 0` check
@pytest.mark.parametrize("call, match", [
    (lambda: geometry.aspect_ratio(1.0, 0.0, 0.0, 0.5), "degenerate outline"),
    (lambda: geometry.aspect_ratio(0.0, 1.0, 0.5, 0.0), "degenerate outline"),
    (lambda: geometry.aspect_ratio(0.0, NAN, 0.0, 0.5), "degenerate outline"),
    (lambda: geometry.aspect_ratio(0.0, INF, 0.0, 0.5), "degenerate outline"),
    (lambda: geometry.calibrate_shape_coefficient(NAN, 3.7, 0.026, 1.8), "strictly positive and finite"),
    (lambda: geometry.reconstruct_dimensions(24.0, INF, 0.026), "strictly positive and finite"),
    (lambda: geometry.reconstruct_dimensions(24.0, 3.7, 0.026, k=NAN), "strictly positive and finite"),
])
def test_geometry_refuses(call, match) -> None:
    with pytest.raises(ValueError, match=match):
        call()


# the first screen: an unsorted t slipped past the end-point check, and an empty t raised IndexError
@pytest.mark.parametrize("t, match", [
    ([], "non-empty 1-D array of finite values"),
    ([0.0, NAN], "non-empty 1-D array of finite values"),
    ([[0.0, 0.5]], "non-empty 1-D array of finite values"),
    ([0.0, 99.0, 1.0], "fall outside the run"),
])
def test_at_samples_refuses(t, match) -> None:
    run = pd.DataFrame({"timestamp": [0.0, 1.0, 2.0], **{c: [0.0, 1.0, 2.0] for c in ids.ACCEL}})
    with pytest.raises(ValueError, match=match):
        ids.at_samples(run, t)


# the surrogate: +-inf reached sklearn's scaler, and an empty frame was not refused
@pytest.fixture(scope="module")
def table():
    return build_training_table()


def test_predict_refuses_inf_and_empty(table) -> None:
    model = SurrogatePredictor().fit(table)
    query = table[model.features].iloc[:1].copy()
    query.iloc[0, 0] = INF
    with pytest.raises(ValueError, match="infinite value"):
        model.predict(query)
    with pytest.raises(ValueError, match="query has no rows"):
        model.predict(table[model.features].iloc[:0])


def test_fit_refuses_inf_and_empty(table) -> None:
    bad = table.copy()
    bad.loc[bad.index[0], "drag_friction_n"] = INF
    with pytest.raises(ValueError, match="infinite value"):
        SurrogatePredictor().fit(bad)
    with pytest.raises(ValueError, match="training table has no rows"):
        SurrogatePredictor().fit(table.iloc[:0])


# physics_baseline: 1024.6 was read as 1025, a NaN passed the `<= 0` checks, a negative k_area was floored
@pytest.mark.parametrize("rho", [1024.6, NAN, INF])
def test_viscosity_needs_an_exact_table_density(rho) -> None:
    with pytest.raises(KeyError, match="not one of SWD's salt-water densities"):
        pb.viscosity_for_density(rho)


@pytest.mark.parametrize("call, match", [
    (lambda: pb.reynolds_number(-5.0, 1.0, 1025, 0.00107), "finite and strictly positive"),
    (lambda: pb.reynolds_number(5.0, NAN, 1025, 0.00107), "finite and strictly positive"),
    (lambda: pb.friction_coefficient(NAN), "Reynolds number must be finite"),
    (lambda: pb.friction_coefficient(1e6, length_m=-1.0, roughness_micron=60.0), "fully-rough branch"),
    (lambda: pb.friction_force(NAN, 1.0), "wetted_length_m must be finite"),
    (lambda: pb.friction_force(1.5, NAN), "wetted_area_m2 must be finite"),
    (lambda: pb.friction_force(1.5, 1.0, velocity_ms=0.0), "velocity_ms must be finite"),
    (lambda: pb.wetted_area_estimate(1.8, 0.5, 0.1, 5.0, k_area=-0.5), "k_area must be finite"),
    (lambda: pb.PhysicsFrictionBaseline().fit(np.array([[1.8, 0.5, 0.1, 5.0]]), np.array([-1.0])),
     "no training row has a positive finite force"),
])
def test_physics_baseline_refuses(call, match) -> None:
    with pytest.raises(ValueError, match=match):
        call()


# the friction modules: a bool passed as 1.0, an array h gave one slope per element, bad grids hit IndexError
@pytest.mark.parametrize("call, match", [
    (lambda: ss.C_f(True), "a bool is not"),
    (lambda: ss.wall_slope([0.0, 0.1, 0.2], np.array([0.1, 0.2])), "single step"),
    (lambda: ss.shoot(-1.0, 0.1), "eta_max must be finite"),
    (lambda: ss.shoot(0.1, 0.1), "at least 3 points"),
    (lambda: ss.shoot(2*ss.STEP_SIZE, ss.STEP_SIZE), "at least 3 points"),
    (lambda: bt.thicknesses(True), "a bool is not"),
    (lambda: fd.blasius_fd(N=1), "N must be an integer >= 2"),
    (lambda: fd.blasius_fd(N=True), "N must be an integer >= 2"),
    (lambda: fd.blasius_fd(h=-0.1), "h must be a finite positive number"),
    (lambda: fd.blasius_fd(h="0.1"), "h must be a finite positive number"),
    (lambda: fd.blasius_fd(iterations=0), "iterations must be an integer >= 1"),
    (lambda: ff.wetted_geometry(pos_y=False), "pos_y must be a finite real scalar"),
    (lambda: ff.wetted_geometry(pos_x=NAN), "pos_x must be a finite real scalar"),
    (lambda: ff.F_f(True, lambda v: v, lambda v: v), "a bool is not"),
    (lambda: fm.load_forces(pos_y=False), "pos_y must be a finite scalar"),
])
def test_friction_and_forward_model_refuse(call, match) -> None:
    with pytest.raises(ValueError, match=match):
        call()


# profiling, splits and evaluate
@pytest.mark.parametrize("call, error, match", [
    (lambda: profiling.arithmetic_intensity(300, 5, bytes_per_float=0), ValueError, "must all be positive"),
    (lambda: profiling.predict_latency(None, np.zeros((3, 5)), batch=0), ValueError, "batch and repeats"),
    (lambda: profiling.predict_latency(None, np.zeros((3, 5)), repeats=0), ValueError, "batch and repeats"),
    (lambda: splits.group_labels(pd.DataFrame({"board": ["a_1", None]})), ValueError, "missing 'board' value"),
    (lambda: evaluate.pooled_score(pd.DataFrame({"x": [1.0]}), "x", "no_such_model"), KeyError,
     "unknown estimator"),
    (lambda: evaluate.nested_lobo(pd.DataFrame({"x": [1.0]}), "missing_target"), KeyError, "not in table"),
    (lambda: evaluate.nested_lobo(pd.DataFrame({"x": [1.0]}), "x", grid=[]), ValueError, "at least one"),
])
def test_tools_refuse(call, error, match) -> None:
    with pytest.raises(error, match=match):
        call()


# SQA round 2 (sqa-lead): the checks sat behind lru_cache, which served True from a cached call made with 1
def test_shoot_checks_run_before_its_cache() -> None:
    ss.shoot(1, ss.STEP_SIZE)
    with pytest.raises(ValueError, match="a bool is not"):
        ss.shoot(True, ss.STEP_SIZE)


def test_load_forces_checks_run_before_its_cache() -> None:
    fm.load_forces(pos_y=0)
    with pytest.raises(ValueError, match="pos_y must be a finite scalar"):
        fm.load_forces(pos_y=False)
    with pytest.raises(ValueError, match="pos_y must be a finite scalar"):
        fm.load_forces(pos_y=np.array([0.0]))  # was TypeError: unhashable type


def test_wetted_geometry_accepts_a_0d_array_like_forward_model() -> None:
    A, L = ff.wetted_geometry(pos_y=np.array(0.0))
    assert np.isfinite(A(8.0)) and np.isfinite(L(8.0))


def test_holdout_split_keeps_a_train_group() -> None:
    """Two boards and test_fraction 0.6 used to move both into test, leaving train empty."""
    two = pd.DataFrame({"board": ["a_1", "a_1", "b_1", "b_1"], "x": [1.0, 2.0, 3.0, 4.0]})
    train, test = splits.holdout_split(two, test_fraction=0.6, level="board")
    assert len(train) > 0 and len(test) > 0
    assert set(train.board).isdisjoint(set(test.board))
