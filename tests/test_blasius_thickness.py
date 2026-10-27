"""Tests for the Blasius boundary-layer thicknesses against White and Majdalani (2022)."""

from __future__ import annotations


import numpy as np
import pytest

from src.friction.blasius_shooting import blasius_thickness as bt

# White and Majdalani (2022), Table 4-3 footnote: the 99 % edge in the book's scaling, eta = y sqrt(U/(2 nu x))
ETA_DELTA_BOOK = 3.471886880405967
# Table 4-4, p.175, the exact Blasius solution: delta*/delta_99, theta/delta_99 and the shape factor
DELTA_STAR_OVER_DELTA_BOOK = 0.35047
THETA_OVER_DELTA_BOOK = 0.13526
H_BOOK = 2.59110

RE_X = np.array([1e3, 1e4, 1e5, 5e5])


def test_eta_99_matches_table_4_3_edge_row() -> None:
    """eta_99 in the project's scaling is sqrt(2) times the book's eta_delta."""
    a, _, _, _ = bt.blasius_coefficients()
    assert a == pytest.approx(np.sqrt(2)*ETA_DELTA_BOOK, abs=1e-5)


def test_shape_factor_matches_table_4_4() -> None:
    """H = delta*/theta against the book. The trapezoidal theta at the RK4 step is about 2e-4 low,
    so H is about 2e-4 high: rel 1e-3 allows for that."""
    _, _, _, H = bt.blasius_coefficients()
    assert H == pytest.approx(H_BOOK, rel=1e-3)


def test_thickness_ratios_match_table_4_4() -> None:
    """delta*/delta_99 and theta/delta_99 against the book, so a factor common to delta* and theta,
    which cancels in H, is caught. delta* is held to the table's 5 decimals; theta has the trapezoid's
    error, so rel 1e-3."""
    a, c, d, _ = bt.blasius_coefficients()
    assert c/a == pytest.approx(DELTA_STAR_OVER_DELTA_BOOK, abs=5e-6)
    assert d/a == pytest.approx(THETA_OVER_DELTA_BOOK, rel=1e-3)


def test_coefficients_same_for_array_and_one_at_a_time() -> None:
    """Multiplying each row by sqrt(Re_x) gives back the same coefficients, whether Re_x is passed as one
    array or one value at a time, and H comes back unchanged."""
    a, c, d, H = bt.blasius_coefficients()

    delta_over_x, H_array = bt.thicknesses(RE_X)
    singles = [bt.thicknesses(Re_x) for Re_x in RE_X]
    delta_over_x_singles = np.vstack([row for row, _ in singles])

    assert delta_over_x.shape == (len(RE_X), 3)
    for coefficients in (delta_over_x*np.sqrt(RE_X)[:, None], delta_over_x_singles*np.sqrt(RE_X)[:, None]):
        np.testing.assert_allclose(coefficients, np.tile([a, c, d], (len(RE_X), 1)), rtol=1e-14, atol=0)
    assert H_array == H
    assert all(H_single == H for _, H_single in singles)


@pytest.mark.parametrize("Re_x, match", [(0.0, "finite and positive"), (-1.0, "finite and positive"),
                                         (np.nan, "finite and positive"), (np.inf, "finite and positive"),
                                         ([1e5, -1.0], "finite and positive"), ([], "non-empty 1-D"),
                                         ([[1e3, 1e4]], "non-empty 1-D")])
def test_rejects_invalid_re_x(Re_x, match) -> None:
    """Re_x must be finite and positive, and one value or a non-empty 1-D array."""
    with pytest.raises(ValueError, match=match):
        bt.thicknesses(Re_x)
