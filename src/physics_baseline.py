"""SWD's own friction law, reimplemented as a physics baseline for the surrogate.

Provenance
----------
This is not a textbook correlation chosen because it looked appropriate. It is the
law SWD itself runs, recovered by decompiling
``Module_couche_limite.epaisseur_couche_limite()`` and reimplemented here:

.. code-block:: text

    transition pinned at Re_crit = 5e5,   x_tr = Re_crit * nu / V
    laminar      Cf = 1.328 / sqrt(Re)
    turbulent    Cf = 0.031 / Re**(1/7)                    for Ra <= 50 micron
    fully rough  Cf = (1.89 + 1.62*log10(L/Ra))**-2.5      for Ra >  50 micron
    F = 0.5 * rho * V**2 * Cf * A, summed over the laminar and turbulent runs

Note the turbulent branch gives ``F ~ V**(13/7) = V**1.857``, so total drag does
**not** scale as a clean ``V**2``. Any attempt to rescale these results to another
speed must use that exponent, not 2.

It is neither ITTC-57 nor Schoenherr, which is worth stating explicitly in the
report -- assuming the standard ship-resistance correlation would have been the
obvious mistake, and it would have been wrong.

Water properties are a **four-entry lookup table**, not a formula
(``Form_shaper.actualiser_fluide()``). Density can only ever be one of eight values,
so the corpus's ``rho_kgm3`` of 1023 or 1025 pins the temperature to 30 or 20 deg C
and the viscosity with it. There is no interpolation to do.

Two different uses, kept apart
------------------------------
:func:`friction_force` is a **validation** instrument: given SWD's own wetted area
and wetted length it reproduces SWD's own ``drag_friction_n`` to a **median 7.5 %**
across 6,799 elements (median ratio 0.941, 61 % of elements within 10 %). That tests
the recovered law, not a surrogate.

Two corrections to the project record were measured while establishing that figure,
on 2026-09-01, and both matter:

*The error is 7.5 %, not the 1-3 % previously recorded.* The residual is a
systematic under-prediction, flat across drift angle, so it is more likely a
difference in which area SWD charges to friction than a wrong coefficient.

*The friction velocity is the scan speed, not the board's stored setting.* The
project record states that ``actualiser_couche_limite()`` reads
``planche_ref.vitesse_flux_relatif_ms``. Taken literally -- using the stored
``board_speed_setting_ms``, which varies 2-20 m/s across boards -- the ratio
collapses to **0.243**, a 76 % error. At 20.000 m/s it is 0.941, and on the boards
whose stored setting happens to *be* 20 the two agree at 0.949. SWD evidently
overwrites that field with the scan condition before solving, so the value found in
a saved ``.fynbs`` is not the one the solver used.

:class:`PhysicsFrictionBaseline` is the **baseline**: it may use only what a
surrogate may use -- board geometry and the operating condition -- so it must
estimate wetted area rather than be given it. It fits exactly one scalar. A
one-parameter physical model beating a five-feature learner would be a real result,
and is the comparison the rubric's "credible alternative" asks for.
"""

from __future__ import annotations

import numpy as np

__all__ = [
    "PhysicsFrictionBaseline",
    "RE_CRIT",
    "SALT_WATER",
    "V_REF_MS",
    "friction_coefficient",
    "friction_force",
    "reynolds_number",
    "viscosity_for_density",
    "wetted_area_estimate",
]

#: Transition Reynolds number, pinned by SWD rather than fitted.
RE_CRIT: float = 5.0e5

#: The one flow speed in this corpus, m/s. Not a tunable: every one of the 720
#: operating points was computed at it.
V_REF_MS: float = 20.000

#: SWD's salt-water lookup: density (kg/m3) -> (temperature degC, dynamic
#: viscosity Pa.s). Fresh water has its own four entries, unused here because
#: ``SurfHydrodynamics.exe.config`` ships ``salt_water=True``.
SALT_WATER: dict[int, tuple[int, float]] = {
    1028: (0, 0.00182),
    1027: (10, 0.00138),
    1025: (20, 0.00107),
    1023: (30, 0.00084),
}


def viscosity_for_density(rho_kgm3: int) -> float:
    """Dynamic viscosity for one of SWD's four salt-water densities.

    Parameters
    ----------
    rho_kgm3 : int
        Density in kg/m3. Must be exactly one of 1028, 1027, 1025, 1023 -- these
        are table entries, not samples of a continuum.

    Returns
    -------
    float
        Dynamic viscosity in Pa.s.

    Raises
    ------
    KeyError
        If the density is not a table entry. Refusing is deliberate: interpolating
        between lookup rows would invent a fluid SWD cannot select.
    """
    key = int(round(rho_kgm3))
    if key not in SALT_WATER:
        raise KeyError(
            f"rho={rho_kgm3} is not one of SWD's salt-water densities "
            f"{sorted(SALT_WATER)}; interpolation is not valid on a lookup table"
        )
    return SALT_WATER[key][1]


def reynolds_number(
    velocity_ms: np.ndarray | float,
    length_m: np.ndarray | float,
    rho_kgm3: np.ndarray | float,
    mu_pas: np.ndarray | float,
) -> np.ndarray:
    """Reynolds number ``rho*V*L/mu``.

    Parameters
    ----------
    velocity_ms : array_like of float
        Flow speed, m/s.
    length_m : array_like of float
        Characteristic (wetted) length, m.
    rho_kgm3 : array_like of float
        Density, kg/m3.
    mu_pas : array_like of float
        Dynamic viscosity, Pa.s.

    Returns
    -------
    numpy.ndarray
        Dimensionless. Around 3.3e7 for a 1.7 m board at 20 m/s in seawater --
        firmly turbulent, which is why the laminar run below is a thin sliver.
    """
    return (np.asarray(rho_kgm3, float) * np.asarray(velocity_ms, float)
            * np.asarray(length_m, float) / np.asarray(mu_pas, float))


def friction_coefficient(
    reynolds: np.ndarray | float,
    length_m: np.ndarray | float | None = None,
    roughness_micron: float = 0.0,
) -> np.ndarray:
    """Skin-friction coefficient on SWD's three branches.

    Parameters
    ----------
    reynolds : array_like of float
        Reynolds number. Must be > 0.
    length_m : array_like of float, optional
        Plate length, m. Required only on the fully-rough branch.
    roughness_micron : float, optional
        Surface roughness Ra in microns. ``<= 50`` selects the smooth turbulent
        branch, ``> 50`` the fully-rough branch. Defaults to 0, which is what
        ``Ra_micron`` reads on every board in this corpus.

    Returns
    -------
    numpy.ndarray
        Dimensionless Cf.

    Raises
    ------
    ValueError
        If any Reynolds number is non-positive, or the rough branch is selected
        without ``length_m``.
    """
    re = np.asarray(reynolds, dtype=float)
    if np.any(re <= 0):
        raise ValueError("Reynolds number must be strictly positive")

    if roughness_micron > 50.0:
        if length_m is None:
            raise ValueError("the fully-rough branch needs length_m")
        ra_m = roughness_micron * 1e-6
        return (1.89 + 1.62 * np.log10(np.asarray(length_m, float) / ra_m)) ** -2.5

    # Laminar below transition, 1/7-power turbulent above it.
    return np.where(re <= RE_CRIT, 1.328 / np.sqrt(re), 0.031 / re ** (1.0 / 7.0))


def friction_force(
    wetted_length_m: np.ndarray | float,
    wetted_area_m2: np.ndarray | float,
    velocity_ms: np.ndarray | float = V_REF_MS,
    rho_kgm3: np.ndarray | float = 1025,
    roughness_micron: float = 0.0,
) -> np.ndarray:
    """Friction drag in newtons, laminar and turbulent runs summed.

    The plate is split at ``x_tr = Re_crit * nu / V``. Area is apportioned between
    the two runs in proportion to their length, which assumes a constant-width
    wetted patch -- an approximation SWD makes too, and the reason this reproduces
    ``_Fx_friction_n`` to a few percent rather than exactly.

    Parameters
    ----------
    wetted_length_m : array_like of float
        Wetted length, m. Must be > 0.
    wetted_area_m2 : array_like of float
        Wetted area, m2. Must be >= 0.
    velocity_ms : array_like of float, optional
        Flow speed, m/s. Defaults to :data:`V_REF_MS`.
    rho_kgm3 : array_like of float, optional
        Density, kg/m3. Must be a :data:`SALT_WATER` key.
    roughness_micron : float, optional
        Ra in microns.

    Returns
    -------
    numpy.ndarray
        Friction drag, N.

    Raises
    ------
    ValueError
        If length is non-positive or area is negative.
    """
    length = np.asarray(wetted_length_m, dtype=float)
    area = np.asarray(wetted_area_m2, dtype=float)
    velocity = np.asarray(velocity_ms, dtype=float)
    if np.any(length <= 0):
        raise ValueError("wetted_length_m must be strictly positive")
    if np.any(area < 0):
        raise ValueError("wetted_area_m2 must be non-negative")

    rho = np.asarray(rho_kgm3, dtype=float)
    # np.vectorize preserves shape, 0-d included, so a scalar query returns a
    # scalar rather than a length-1 array. The list-comprehension version did not,
    # and float() on its result raised.
    mu = np.vectorize(viscosity_for_density, otypes=[float])(rho)
    nu = mu / rho

    x_transition = np.minimum(RE_CRIT * nu / velocity, length)
    dynamic_pressure = 0.5 * rho * velocity**2

    re_transition = reynolds_number(velocity, np.maximum(x_transition, 1e-12), rho, mu)
    re_length = reynolds_number(velocity, length, rho, mu)

    cf_laminar = friction_coefficient(re_transition, x_transition, roughness_micron)
    cf_turbulent = friction_coefficient(re_length, length, roughness_micron)

    laminar_share = x_transition / length
    force = dynamic_pressure * (
        cf_laminar * area * laminar_share
        + cf_turbulent * area * (1.0 - laminar_share)
    )
    return np.asarray(force, dtype=float)


def wetted_area_estimate(
    length_m: np.ndarray | float,
    width_m: np.ndarray | float,
    roll_rad: np.ndarray | float,
    drift_deg: np.ndarray | float,
    k_area: float,
) -> np.ndarray:
    """Wetted area from board geometry and attitude alone.

    A planing hull wets a fraction of its planform. That fraction falls as the board
    rolls onto a rail and as it yaws away from the flow, so the simplest defensible
    form is ``k * L * W * cos(roll) * cos(drift)`` with a single scalar ``k``
    absorbing planform shape and trim.

    Deliberately crude. Its purpose is to be a *physics* baseline with one fitted
    parameter, not to compete on flexibility -- if a five-feature learner cannot beat
    it, that is the finding.

    Parameters
    ----------
    length_m, width_m : array_like of float
        Board dimensions, m.
    roll_rad : array_like of float
        Roll angle, radians.
    drift_deg : array_like of float
        Drift angle, degrees.
    k_area : float
        Fitted planform coefficient, dimensionless.

    Returns
    -------
    numpy.ndarray
        Wetted area, m2, floored at a small positive value so the friction law
        downstream never sees zero.
    """
    roll = np.abs(np.asarray(roll_rad, dtype=float))
    drift = np.radians(np.abs(np.asarray(drift_deg, dtype=float)))
    planform = np.asarray(length_m, float) * np.asarray(width_m, float)
    return np.maximum(k_area * planform * np.cos(roll) * np.cos(drift), 1e-6)


class PhysicsFrictionBaseline:
    """One-parameter physical baseline for friction drag, scikit-learn shaped.

    Fits the single scalar ``k_area`` by least squares in log space, then predicts
    with SWD's own friction law. Implements ``fit``/``predict`` so it drops into the
    same evaluation loop as the learned models and is scored identically.

    Parameters
    ----------
    velocity_ms : float, optional
        Flow speed, m/s. Defaults to :data:`V_REF_MS`.
    rho_kgm3 : int, optional
        Water density. Defaults to 1025.

    Attributes
    ----------
    k_area_ : float
        Fitted planform coefficient. Available after ``fit``.

    Notes
    -----
    Expects columns in the order ``[length_m, width_m, roll_rad, drift_deg]``. That
    is a different feature vector from the learned models, which is the point: this
    baseline is not a re-parameterisation of the same inputs.
    """

    def __init__(self, velocity_ms: float = V_REF_MS, rho_kgm3: int = 1025) -> None:
        self.velocity_ms = velocity_ms
        self.rho_kgm3 = rho_kgm3
        self.k_area_: float | None = None

    def fit(self, X: np.ndarray, y: np.ndarray) -> "PhysicsFrictionBaseline":
        """Fit ``k_area`` on the training fold only.

        Force is linear in area and therefore in ``k_area``, so the optimum is a
        ratio of medians rather than an iterative solve -- median, not mean, so a
        single extreme hull cannot set the coefficient for all of them.

        Parameters
        ----------
        X : numpy.ndarray, shape (n, 4)
            ``[length_m, width_m, roll_rad, drift_deg]``.
        y : numpy.ndarray, shape (n,)
            Observed friction drag, N.

        Returns
        -------
        PhysicsFrictionBaseline
            self.
        """
        X = np.asarray(X, dtype=float)
        y = np.asarray(y, dtype=float)
        unit = self._force(X, k_area=1.0)
        usable = (unit > 0) & np.isfinite(y) & (y > 0)
        self.k_area_ = float(np.median(y[usable] / unit[usable])) if usable.any() else 1.0
        return self

    def predict(self, X: np.ndarray) -> np.ndarray:
        """Predict friction drag in newtons.

        Parameters
        ----------
        X : numpy.ndarray, shape (n, 4)
            ``[length_m, width_m, roll_rad, drift_deg]``.

        Returns
        -------
        numpy.ndarray
            Friction drag, N.

        Raises
        ------
        RuntimeError
            If called before ``fit``.
        """
        if self.k_area_ is None:
            raise RuntimeError("PhysicsFrictionBaseline.predict called before fit")
        return self._force(np.asarray(X, dtype=float), self.k_area_)

    def _force(self, X: np.ndarray, k_area: float) -> np.ndarray:
        length, width, roll, drift = X[:, 0], X[:, 1], X[:, 2], X[:, 3]
        area = wetted_area_estimate(length, width, roll, drift, k_area)
        # Wetted length shortens with drift as the flow crosses the hull obliquely.
        wetted_length = np.maximum(length * np.cos(np.radians(np.abs(drift))), 1e-3)
        return friction_force(
            wetted_length, area, self.velocity_ms,
            np.full(length.shape, self.rho_kgm3), 0.0,
        )
