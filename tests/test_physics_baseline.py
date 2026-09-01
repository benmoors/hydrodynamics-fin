"""Verification of the recovered friction law, and validation against SWD.

The analytical cases here have closed-form answers -- a flat plate's Blasius
coefficient is ``1.328/sqrt(Re)`` exactly, and the dynamic pressure of a known flow
is arithmetic -- so they test the implementation rather than the physics. The
validation class at the bottom tests the physics, against SWD's own numbers.
"""

from __future__ import annotations

import numpy as np
import pytest

from src.physics_baseline import (
    RE_CRIT,
    SALT_WATER,
    V_REF_MS,
    PhysicsFrictionBaseline,
    friction_coefficient,
    friction_force,
    reynolds_number,
    viscosity_for_density,
    wetted_area_estimate,
)


class TestWaterProperties:
    def test_all_four_salt_entries_present(self):
        assert sorted(SALT_WATER) == [1023, 1025, 1027, 1023 + 5]  # 1023,1025,1027,1028

    def test_default_config_density_is_20C(self):
        """SurfHydrodynamics.exe.config ships temperature_eau=20, salt_water=True."""
        temperature, viscosity = SALT_WATER[1025]
        assert temperature == 20
        assert viscosity == pytest.approx(0.00107)

    def test_off_table_density_refuses(self):
        """A lookup table has no between-rows. Interpolating would invent a fluid."""
        with pytest.raises(KeyError, match="not one of SWD's salt-water densities"):
            viscosity_for_density(1024)


class TestReynolds:
    def test_analytical_value(self):
        """rho=1000, V=1, L=1, mu=0.001 -> Re = 1e6 exactly."""
        assert float(reynolds_number(1.0, 1.0, 1000.0, 0.001)) == pytest.approx(1e6)

    def test_board_scale_is_turbulent(self):
        """A 1.7 m board at 20 m/s in seawater is far past transition."""
        re = float(reynolds_number(V_REF_MS, 1.7, 1025, viscosity_for_density(1025)))
        # Measured 3.26e7, i.e. 65x transition -- turbulent over all but the first
        # ~26 mm of the plate. The original assertion said 100x and was simply wrong.
        assert re > 10 * RE_CRIT
        assert re == pytest.approx(3.26e7, rel=0.02)


class TestFrictionCoefficient:
    def test_laminar_branch_is_blasius(self):
        """Below Re_crit the coefficient must be exactly 1.328/sqrt(Re)."""
        re = 1.0e4
        assert float(friction_coefficient(re)) == pytest.approx(1.328 / np.sqrt(re), rel=1e-12)

    def test_turbulent_branch_is_one_seventh_power(self):
        re = 1.0e7
        assert float(friction_coefficient(re)) == pytest.approx(0.031 / re ** (1 / 7), rel=1e-12)

    def test_switches_exactly_at_re_crit(self):
        below = float(friction_coefficient(RE_CRIT))
        above = float(friction_coefficient(RE_CRIT * 1.0001))
        assert below == pytest.approx(1.328 / np.sqrt(RE_CRIT), rel=1e-9)
        assert above == pytest.approx(0.031 / (RE_CRIT * 1.0001) ** (1 / 7), rel=1e-9)

    def test_decreases_with_reynolds(self):
        re = np.array([1e6, 1e7, 1e8])
        cf = friction_coefficient(re)
        assert np.all(np.diff(cf) < 0)

    def test_rough_branch_needs_a_length(self):
        with pytest.raises(ValueError, match="needs length_m"):
            friction_coefficient(1e7, roughness_micron=100.0)

    def test_rough_branch_is_reynolds_independent(self):
        """Fully rough Cf depends on L/Ra only -- that is what 'fully rough' means."""
        a = friction_coefficient(1e7, length_m=1.7, roughness_micron=100.0)
        b = friction_coefficient(1e9, length_m=1.7, roughness_micron=100.0)
        assert float(a) == pytest.approx(float(b), rel=1e-12)

    def test_non_positive_reynolds_refuses(self):
        with pytest.raises(ValueError, match="strictly positive"):
            friction_coefficient(0.0)


class TestFrictionForce:
    def test_scales_with_area(self):
        """Force is linear in wetted area at fixed length and speed."""
        one = float(friction_force(1.7, 0.5, 20.0, 1025))
        two = float(friction_force(1.7, 1.0, 20.0, 1025))
        assert two == pytest.approx(2.0 * one, rel=1e-12)

    def test_velocity_exponent_is_13_over_7_not_2(self):
        """The turbulent branch gives F ~ V**(13/7). Documented, and easy to assume wrong."""
        low = float(friction_force(1.7, 1.0, 10.0, 1025))
        high = float(friction_force(1.7, 1.0, 20.0, 1025))
        assert np.log2(high / low) == pytest.approx(13 / 7, rel=0.02)
        assert np.log2(high / low) != pytest.approx(2.0, rel=0.02)

    def test_zero_area_gives_zero_force(self):
        assert float(friction_force(1.7, 0.0, 20.0, 1025)) == pytest.approx(0.0)

    @pytest.mark.parametrize(
        "args, match",
        [((0.0, 1.0), "wetted_length_m"), ((1.7, -1.0), "wetted_area_m2")],
        ids=["zero-length", "negative-area"],
    )
    def test_invalid_geometry_refuses(self, args, match):
        with pytest.raises(ValueError, match=match):
            friction_force(*args, 20.0, 1025)


class TestWettedAreaEstimate:
    def test_falls_with_roll_and_drift(self):
        flat = float(wetted_area_estimate(1.8, 0.5, 0.0, 0.0, 0.5))
        rolled = float(wetted_area_estimate(1.8, 0.5, 0.6, 0.0, 0.5))
        drifted = float(wetted_area_estimate(1.8, 0.5, 0.0, 20.0, 0.5))
        assert rolled < flat and drifted < flat

    def test_never_returns_zero(self):
        """The friction law divides by length and multiplies by area; a zero here
        would propagate as a silent zero force rather than an error."""
        assert float(wetted_area_estimate(1.8, 0.5, np.pi / 2, 90.0, 0.5)) > 0


class TestPhysicsBaselineEstimator:
    def _X(self, n=40):
        rng = np.random.default_rng(0)
        return np.column_stack([
            rng.uniform(1.6, 3.2, n), rng.uniform(0.4, 0.75, n),
            rng.uniform(-0.2, 1.3, n), rng.uniform(0, 20, n),
        ])

    def test_recovers_a_planted_coefficient(self):
        """Generate with a known k, fit, and get k back. Force is linear in k."""
        X = self._X()
        truth = PhysicsFrictionBaseline()
        truth.k_area_ = 0.42
        y = truth.predict(X)
        assert PhysicsFrictionBaseline().fit(X, y).k_area_ == pytest.approx(0.42, rel=1e-9)

    def test_predict_before_fit_refuses(self):
        with pytest.raises(RuntimeError, match="before fit"):
            PhysicsFrictionBaseline().predict(self._X())

    def test_is_a_one_parameter_model(self):
        """The whole claim of this baseline. If it ever gains parameters, the
        comparison against a five-feature learner stops being interesting."""
        model = PhysicsFrictionBaseline().fit(self._X(), np.full(40, 100.0))
        fitted = [a for a in vars(model) if a.endswith("_") and getattr(model, a) is not None]
        assert fitted == ["k_area_"]
