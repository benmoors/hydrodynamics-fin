"""Negative tests for the input checks added in SQA round 1 (2026-10-28), one per refused input, each with match=.

agy and Devin found each of these inputs passing silently, or failing with an unrelated error, before the check.
"""

from __future__ import annotations

import numpy as np
import pytest

from src.forward_model import forward_model as fm
from src.friction import friction_force as ff
from src.friction.blasius_shooting import blasius_thickness as bt
from src.friction.blasius_shooting import fd_blasius as fd
from src.friction.blasius_shooting import skin_and_shear as ss
from src.friction.von_karman import von_karman as vk

NAN = float("nan")


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


# SQA round 3 (agy, Devin): booleans read as 0 or 1
ONES = lambda v: np.ones_like(np.asarray(v, dtype=float))  # noqa: E731  a stand-in A(V) and L(V)


@pytest.mark.parametrize("call, match", [
    (lambda: ff.F_f(6.0, ONES, ONES, rho=True), "rho and mu must be"),
    (lambda: ff.F_f(6.0, ONES, ONES, mu="0.00107"), "rho and mu must be"),
    (lambda: vk.profile(True), "a bool is not"),
    (lambda: ss.wall_slope([False, True, True], 0.1), "a bool is not"),
])
def test_round_3_refusals(call, match) -> None:
    with pytest.raises(ValueError, match=match):
        call()


# The author's decisions of 2026-10-28 (AI-USE.md section 4)
from src.friction.blasius_shooting import shooting_blasius as sb  # noqa: E402


def test_thicknesses_refuses_above_the_laminar_range() -> None:
    with pytest.raises(ValueError, match=r"at most 1e\+06"):
        bt.thicknesses(2e6)


def test_secant_names_its_failure() -> None:
    with pytest.raises(ValueError, match="would divide by zero"):
        sb.secant_for_shooting(lambda s: 1.0, 0.5, 0.6)  # a flat F
    with pytest.raises(ValueError, match="did not reach"):
        sb.secant_for_shooting(lambda s: s**3 - 0.33, 0.1, 0.2, max_iter=1)
    with pytest.raises(ValueError, match="second guess s = 5.0 is not finite"):
        sb.secant_for_shooting(lambda s: float("nan") if s > 1 else s, 0.0, 5.0)


def test_F_f_checks_a_passed_fluid_but_not_the_defaults(monkeypatch) -> None:
    """rho and mu are checked where they enter: a passed value each call, the module's own once at import."""
    calls = []
    monkeypatch.setattr(ff, "_check_fluid", lambda rho, mu: calls.append((rho, mu)))
    ff.F_f(6.0, ONES, ONES)
    assert calls == []
    ff.F_f(6.0, ONES, ONES, rho=1025.0)
    assert calls == [(1025.0, ff.MU)]


# agy and Devin, 2026-10-28, on remove-part-a: the helpers screen 2 took from the first screen, and s_star
from src.swd_model import identifiability_screen_live as live  # noqa: E402


@pytest.mark.parametrize("call, match", [
    (lambda: live.quiet_window(live.load_mmc1(), 2), "an integer from 3 to 148"),
    (lambda: live.quiet_window(live.load_mmc1(), 149), "an integer from 3 to 148"),
    (lambda: live.quiet_window(live.load_mmc1(), True), "an integer from 3 to 148"),
    (lambda: live.majority_sign_fraction(np.array([])), "non-empty curve of finite values"),
    (lambda: live.majority_sign_fraction(np.array([NAN, 1.0])), "non-empty curve of finite values"),
    (lambda: live.standard_error("corr", 2.0, 10), "outside"),
    (lambda: live.standard_error("sd", -1.0, 10), "outside"),
    (lambda: live.standard_error("fraction", 1.5, 10), "outside"),
    (lambda: live.standard_error("mean", 1.0, True), "a bool is not"),
    (lambda: live.standard_error("median", 1.0, 10), "kind must be"),
    (lambda: live.continuous_range(np.array([])), "speeds is empty"),
    (lambda: ss.C_f(1e4, s_star=[0.3, 0.4]), "s_star must be a single number"),
])
def test_part_b_review_refusals(call, match) -> None:
    with pytest.raises(ValueError, match=match):
        call()


def test_standard_error_still_passes_nan_through() -> None:
    """A NaN statistic (no converged fits, or set a's V0) gives a NaN SE, as mc_stats relies on."""
    assert np.isnan(live.standard_error("corr", NAN, 10))


# The author's decision, 2026-10-28: input checks in his shooting code, and precision <= 0, max_iter < 1 in the secant
@pytest.mark.parametrize("call, match", [
    (lambda: sb.exact_blasius(False), "eta must be a single finite number"),
    (lambda: sb.exact_blasius(NAN), "eta must be a single finite number"),  # returned row 0
    (lambda: sb.exact_blasius([0.1, 0.2]), "eta must be a single finite number"),
    (lambda: sb.secant_for_shooting(lambda s: s - 0.33, False, True), "s_old must be a single finite number"),
    (lambda: sb.secant_for_shooting(lambda s: s - 0.33, 0.1, NAN), "s_init must be a single finite number"),
    (lambda: sb.secant_for_shooting(lambda s: s - 0.33, 0.1, 0.2, precision=0.0), "precision must be > 0"),
    (lambda: sb.secant_for_shooting(lambda s: s - 0.33, 0.1, 0.2, precision=-1.0), "precision must be > 0"),
    (lambda: sb.secant_for_shooting(lambda s: s - 0.33, 0.1, 0.2, precision=NAN), "precision must be a single"),
    (lambda: sb.secant_for_shooting(lambda s: s - 0.33, 0.1, 0.2, max_iter=0), "max_iter must be an integer >= 1"),
    (lambda: sb.secant_for_shooting(lambda s: s - 0.33, 0.1, 0.2, max_iter=True), "max_iter must be an integer >= 1"),
    (lambda: sb.secant_for_shooting(lambda s: s - 0.33, 0.1, 0.2, max_iter=2.5), "max_iter must be an integer >= 1"),
])
def test_shooting_refuses(call, match) -> None:
    with pytest.raises(ValueError, match=match):
        call()
