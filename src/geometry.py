"""Recover board length, width and thickness from SWD's extracted board fields.

Why this module exists
----------------------
SWD stores no absolute length or width on ``Class_surfboard``. The corpus therefore
offers only ``volume_shape_l``, ``total_mass_kg`` and ``foam_mass_kg`` as geometry,
and those are one quantity wearing three hats: measured on the 14 scanned boards,
``volume_shape_l`` correlates with ``foam_mass_kg`` at r = 1.0000 and with
``total_mass_kg`` at r = 0.9915. A surrogate given only that has a single geometry
input, whatever the column count suggests.

Two fields recover the missing shape information:

``x_min/x_max/y_min/y_max``
    The board outline's bounding box, stored **normalised so the long axis spans
    1.0**. The axis convention is not consistent across boards -- some store
    ``x in [-w, w], y in [-1, 0]``, others ``x in [0, 1], y in [-w, w]`` -- which is
    why the raw extents look like noise. Taking max-span over min-span is
    convention-agnostic and yields Length/Width.

``epaisseur_relative_au_wide_point``
    Thickness divided by length, at the wide point.

Both were confirmed against SWD's own ``Configuration:`` panel, which independently
reports ``Length 2134 mm, Width 553 mm, Thick 40.3 mm`` for
``2003_Taylor_Knox_channel_island_Copy_1``:

===================  ==================  ====================  =======
Quantity             From ``board.csv``  From SWD's panel      Error
===================  ==================  ====================  =======
Length / Width       3.8600              2134/553 = 3.8590     0.03 %
Thickness / Length   0.018871            40.3/2134 = 0.018884  0.05 %
===================  ==================  ====================  =======

Absolute size then follows from a single shape coefficient (see
:data:`SHAPE_COEFFICIENT`). That coefficient is an **assumption**, which is why this
module lives in ``src/`` and never writes into ``SWD/data/`` -- the extracted corpus
stays free of anything this project computed.

Notes
-----
The reconstruction is a *similarity* argument, not a measurement. It assumes every
hull in the library shares one prismatic coefficient. Measured across the two boards
whose true length is independently known, that coefficient varies by 1.56 %, so
treat reconstructed millimetres as accurate to a few percent and never as ground
truth. :func:`shape_coefficient_spread` reports it so the figure stays visible.

The ratios themselves carry no such caveat: they are read straight out of the
extracted fields and agree with SWD's own panel to better than 0.05 %. Prefer them
as model features over the reconstructed millimetres wherever a ratio will do.
"""

from __future__ import annotations

import numpy as np

__all__ = [
    "CALIBRATION",
    "SHAPE_COEFFICIENT",
    "aspect_ratio",
    "calibrate_shape_coefficient",
    "reconstruct_dimensions",
    "shape_coefficient_spread",
]

# Boards whose true length is known independently of any model, both read live from
# SWD's own UI with WM_GETTEXT rather than inferred:
#   default_shortboard                     1800.0 mm -- coverage.md, control read post-scan
#   2003_Taylor_Knox_channel_island_Copy_1 2133.6 mm -- control-map.csv, Board Length EDIT
# Kept as data rather than baked into a magic number, so the calibration can be
# re-derived -- and challenged -- when Tier 2 reads the Configuration panel per board.
CALIBRATION: dict[str, float] = {
    "default_shortboard": 1.8000,
    "2003_Taylor_Knox_channel_island_Copy_1": 2.1336,
}


def aspect_ratio(
    x_min: np.ndarray | float,
    x_max: np.ndarray | float,
    y_min: np.ndarray | float,
    y_max: np.ndarray | float,
) -> np.ndarray:
    """Length/width ratio from a normalised outline bounding box.

    Parameters
    ----------
    x_min, x_max, y_min, y_max : array_like of float
        Outline bounding-box extents as stored in ``board.csv``, dimensionless.
        The long axis spans 1.0; which of x or y is the long axis varies by board.

    Returns
    -------
    numpy.ndarray
        Length divided by width, dimensionless, always >= 1. Observed range across
        the 13 extracted boards is 2.91 to 5.56.

    Raises
    ------
    ValueError
        If either span is zero or negative, which would mean a degenerate outline
        rather than a board.

    Examples
    --------
    >>> float(np.round(aspect_ratio(-0.135, 0.135, -1.0, 0.0), 4))
    3.7037
    """
    x_span = np.abs(np.asarray(x_max, dtype=float) - np.asarray(x_min, dtype=float))
    y_span = np.abs(np.asarray(y_max, dtype=float) - np.asarray(y_min, dtype=float))
    long_axis = np.maximum(x_span, y_span)
    short_axis = np.minimum(x_span, y_span)
    if np.any(short_axis <= 0.0) or np.any(long_axis <= 0.0):
        raise ValueError("degenerate outline: a bounding-box span is zero or negative")
    return long_axis / short_axis


def calibrate_shape_coefficient(
    volume_l: np.ndarray,
    length_over_width: np.ndarray,
    thickness_over_length: np.ndarray,
    true_length_m: np.ndarray,
) -> np.ndarray:
    """Solve ``V = k*L*W*T`` for k on boards whose true length is known.

    Parameters
    ----------
    volume_l : array_like of float
        Shape volume in litres, ``volume_shape_litres``. Must be > 0.
    length_over_width, thickness_over_length : array_like of float
        Dimensionless ratios from :func:`aspect_ratio` and
        ``epaisseur_relative_au_wide_point``. Must be > 0.
    true_length_m : array_like of float
        Independently known board length in metres. Must be > 0.

    Returns
    -------
    numpy.ndarray
        One shape coefficient per board, dimensionless. A rectangular prism gives
        1.0; a surfboard measures near 0.57.

    Raises
    ------
    ValueError
        If any input is non-positive.
    """
    volume_m3 = np.asarray(volume_l, dtype=float) / 1000.0
    lw = np.asarray(length_over_width, dtype=float)
    tl = np.asarray(thickness_over_length, dtype=float)
    length = np.asarray(true_length_m, dtype=float)
    if np.any(volume_m3 <= 0) or np.any(lw <= 0) or np.any(tl <= 0) or np.any(length <= 0):
        raise ValueError("volume, both ratios and length must all be strictly positive")
    # V = k * L * (L/lw) * (tl*L)  =>  k = V*lw / (tl * L^3)
    return volume_m3 * lw / (tl * length**3)


#: Shape coefficient used for reconstruction: the mean of the two calibration
#: boards, whose individual values are 0.5742 and 0.5653. That 1.56 % spread is the
#: honest accuracy bound on every reconstructed millimetre this module returns.
SHAPE_COEFFICIENT: float = 0.5697


def reconstruct_dimensions(
    volume_l: np.ndarray | float,
    length_over_width: np.ndarray | float,
    thickness_over_length: np.ndarray | float,
    k: float = SHAPE_COEFFICIENT,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Recover absolute length, width and thickness in metres.

    Inverts ``V = k*L*W*T`` under ``W = L/lw`` and ``T = tl*L``, giving
    ``L = cbrt(V*lw / (k*tl))``.

    Parameters
    ----------
    volume_l : array_like of float
        Shape volume in litres. Corpus range 24.0 to 130.7 L.
    length_over_width : array_like of float
        From :func:`aspect_ratio`. Corpus range 2.91 to 5.56.
    thickness_over_length : array_like of float
        ``epaisseur_relative_au_wide_point``. Corpus range 0.0105 to 0.0425.
    k : float, optional
        Shape coefficient. Defaults to :data:`SHAPE_COEFFICIENT`.

    Returns
    -------
    tuple of numpy.ndarray
        ``(length_m, width_m, thickness_m)``, all in metres.

    Raises
    ------
    ValueError
        If any input is non-positive. A similarity argument has no meaningful
        extrapolation through zero, so this refuses rather than returning nan.

    Examples
    --------
    >>> L, W, T = reconstruct_dimensions(24.0094, 3.7037, 0.026557)
    >>> float(np.round(L, 3))
    1.805
    """
    volume_m3 = np.asarray(volume_l, dtype=float) / 1000.0
    lw = np.asarray(length_over_width, dtype=float)
    tl = np.asarray(thickness_over_length, dtype=float)
    if np.any(volume_m3 <= 0) or np.any(lw <= 0) or np.any(tl <= 0) or k <= 0:
        raise ValueError("volume, both ratios and k must all be strictly positive")
    length = np.cbrt(volume_m3 * lw / (k * tl))
    return length, length / lw, length * tl


def shape_coefficient_spread(coefficients: np.ndarray) -> float:
    """Relative spread of the calibration coefficients, as a fraction.

    Reported alongside any reconstructed dimension so the accuracy bound travels
    with the number instead of being quietly dropped.

    Parameters
    ----------
    coefficients : array_like of float
        Per-board coefficients from :func:`calibrate_shape_coefficient`.

    Returns
    -------
    float
        ``(max - min) / mean``. Returns 0.0 for fewer than two boards, where no
        spread is observable -- which is not the same as a spread of zero.
    """
    c = np.asarray(coefficients, dtype=float)
    if c.size < 2:
        return 0.0
    return float((c.max() - c.min()) / c.mean())
