"""Verification of the geometry reconstruction.

Two kinds of test live here, and the distinction matters for the report.

*Code verification* asks whether the arithmetic implements the algebra: exercised
against a rectangular prism, whose exact volume is known in closed form, and by a
round trip that must return what it was given.

*Validation* asks whether the algebra describes SWD. That is what
``test_matches_swd_configuration_panel`` does -- it checks our ratios against
numbers SWD itself printed, obtained through a completely different route (a
``WM_GETTEXT`` read of the live Shape Room panel, not deserialisation of a binary).
An agreement there is evidence about the world; the prism test is not.
"""

from __future__ import annotations

import numpy as np
import pytest

from src.geometry import (
    CALIBRATION,
    SHAPE_COEFFICIENT,
    aspect_ratio,
    calibrate_shape_coefficient,
    reconstruct_dimensions,
    shape_coefficient_spread,
)

# SWD's own Configuration panel for 2003_Taylor_Knox_channel_island_Copy_1, read
# from the live control and recorded in phase2/control-map.csv. Independent of
# every number this project derives from the binary reports.
PANEL_LENGTH_MM = 2134.0
PANEL_WIDTH_MM = 553.0
PANEL_THICK_MM = 40.3

# The same board as extracted by extract_board.ps1 into board.csv.
TAYLOR_BOX = (0.0, 1.0, -0.12954, 0.12954)
TAYLOR_TL = 0.0188707
TAYLOR_VOLUME_L = 26.8458461761475


class TestAspectRatio:
    def test_rectangle_with_known_ratio(self):
        """A 4:1 box must read 4:1, whichever axis is long."""
        assert aspect_ratio(0.0, 1.0, -0.125, 0.125) == pytest.approx(4.0)

    def test_axis_convention_is_irrelevant(self):
        """The corpus stores the outline both ways round; both must agree.

        This is the whole reason the raw extents looked like noise -- some boards
        put length on y, others on x.
        """
        length_on_y = aspect_ratio(-0.135, 0.135, -1.0, 0.0)
        length_on_x = aspect_ratio(0.0, 1.0, -0.135, 0.135)
        assert length_on_y == pytest.approx(length_on_x)
        assert length_on_y == pytest.approx(1.0 / 0.27, rel=1e-9)

    def test_is_never_below_one(self):
        ratios = aspect_ratio(
            np.array([0.0, -0.5]), np.array([1.0, 0.5]),
            np.array([-0.2, -1.0]), np.array([0.2, 1.0]),
        )
        assert np.all(ratios >= 1.0)

    @pytest.mark.parametrize(
        "box",
        [(0.0, 0.0, -1.0, 0.0), (0.0, 1.0, 0.5, 0.5)],
        ids=["zero-x-span", "zero-y-span"],
    )
    def test_degenerate_outline_refuses(self, box):
        with pytest.raises(ValueError, match="degenerate outline"):
            aspect_ratio(*box)


class TestReconstruction:
    def test_rectangular_prism_is_exact(self):
        """With k = 1 the model IS a box, so recovery must be exact.

        L = 2 m, W = 0.5 m, T = 0.05 m -> V = 0.05 m^3 = 50 L, lw = 4, tl = 0.025.
        """
        L, W, T = reconstruct_dimensions(50.0, 4.0, 0.025, k=1.0)
        assert float(L) == pytest.approx(2.0, rel=1e-12)
        assert float(W) == pytest.approx(0.5, rel=1e-12)
        assert float(T) == pytest.approx(0.05, rel=1e-12)

    def test_round_trip_preserves_volume(self):
        """Reconstruct, then recompute V = k*L*W*T. Must return the input."""
        volume_l, lw, tl = 47.2, 4.54, 0.0105
        L, W, T = reconstruct_dimensions(volume_l, lw, tl)
        recovered_l = SHAPE_COEFFICIENT * float(L) * float(W) * float(T) * 1000.0
        assert recovered_l == pytest.approx(volume_l, rel=1e-9)

    def test_ratios_are_preserved(self):
        L, W, T = reconstruct_dimensions(84.6, 5.56, 0.0332)
        assert float(L / W) == pytest.approx(5.56, rel=1e-9)
        assert float(T / L) == pytest.approx(0.0332, rel=1e-9)

    def test_vectorises(self):
        L, W, T = reconstruct_dimensions(
            np.array([24.0094, 130.6916]),
            np.array([3.7037, 3.9700]),
            np.array([0.026557, 0.034300]),
        )
        assert L.shape == (2,)
        assert np.all(L > 0) and np.all(W > 0) and np.all(T > 0)

    def test_scales_as_cube_root_of_volume(self):
        """Doubling volume at fixed shape must scale every length by 2**(1/3)."""
        L1, _, _ = reconstruct_dimensions(30.0, 3.7, 0.026)
        L2, _, _ = reconstruct_dimensions(60.0, 3.7, 0.026)
        assert float(L2 / L1) == pytest.approx(2.0 ** (1 / 3), rel=1e-12)

    @pytest.mark.parametrize(
        "args",
        [(0.0, 3.7, 0.026), (-1.0, 3.7, 0.026), (24.0, 0.0, 0.026), (24.0, 3.7, 0.0)],
        ids=["zero-volume", "negative-volume", "zero-lw", "zero-tl"],
    )
    def test_non_positive_input_refuses(self, args):
        with pytest.raises(ValueError, match="strictly positive"):
            reconstruct_dimensions(*args)

    def test_non_positive_k_refuses(self):
        with pytest.raises(ValueError, match="strictly positive"):
            reconstruct_dimensions(24.0, 3.7, 0.026, k=0.0)


class TestCalibration:
    def test_recovers_a_planted_coefficient(self):
        """Round trip through the calibration: plant k, recover k."""
        planted = 0.63
        L, W, T = reconstruct_dimensions(40.0, 3.5, 0.028, k=planted)
        recovered = calibrate_shape_coefficient(40.0, 3.5, 0.028, L)
        assert float(recovered) == pytest.approx(planted, rel=1e-12)

    def test_spread_is_reported_not_hidden(self):
        assert shape_coefficient_spread(np.array([0.5742, 0.5653])) == pytest.approx(
            (0.5742 - 0.5653) / ((0.5742 + 0.5653) / 2), rel=1e-9
        )

    def test_spread_of_single_board_is_zero(self):
        """One board shows no spread; that is absence of evidence, not zero error."""
        assert shape_coefficient_spread(np.array([0.57])) == 0.0

    def test_module_constant_matches_the_two_calibration_boards(self):
        """SHAPE_COEFFICIENT must stay the mean of what CALIBRATION implies.

        Guards against the constant and the data drifting apart -- the constant is
        quoted in the report, so a silent divergence would falsify it.
        """
        volumes = np.array([24.0094108581543, 26.8458461761475])
        lw = np.array([1.0 / 0.269985, 1.0 / 0.2590755])
        tl = np.array([0.0265570562332869, 0.0188707])
        lengths = np.array(list(CALIBRATION.values()))
        k = calibrate_shape_coefficient(volumes, lw, tl, lengths)
        assert float(k.mean()) == pytest.approx(SHAPE_COEFFICIENT, abs=5e-4)
        assert shape_coefficient_spread(k) < 0.02


class TestValidationAgainstSWD:
    """Not code verification -- evidence that the model describes SWD."""

    def test_matches_swd_configuration_panel(self):
        """Our ratios vs numbers SWD printed, reached by a different mechanism."""
        ours_lw = float(aspect_ratio(*TAYLOR_BOX))
        panel_lw = PANEL_LENGTH_MM / PANEL_WIDTH_MM
        assert ours_lw == pytest.approx(panel_lw, rel=2e-3)

        panel_tl = PANEL_THICK_MM / PANEL_LENGTH_MM
        assert TAYLOR_TL == pytest.approx(panel_tl, rel=2e-3)

    def test_reconstructs_a_known_length(self):
        """Taylor Knox is 2133.6 mm by WM_GETTEXT. Reconstruct it from the binary.

        Tolerance is 3 %, set by the 1.56 % calibration spread rather than by
        whatever happens to pass.
        """
        L, W, T = reconstruct_dimensions(TAYLOR_VOLUME_L, aspect_ratio(*TAYLOR_BOX), TAYLOR_TL)
        assert float(L) * 1000.0 == pytest.approx(PANEL_LENGTH_MM, rel=0.03)
        assert float(W) * 1000.0 == pytest.approx(PANEL_WIDTH_MM, rel=0.03)
        assert float(T) * 1000.0 == pytest.approx(PANEL_THICK_MM, rel=0.03)
