"""Unit tests for the ACSM-equation calorie estimation."""

import pytest

from z1_walkingpad_mcp.metrics import CalorieTracker, kcal_per_minute, met_for_speed, vo2_for_speed


def test_resting_is_one_met():
    assert vo2_for_speed(0.0) == pytest.approx(3.5)
    assert met_for_speed(0.0) == pytest.approx(1.0)


def test_acsm_walking_equation():
    # 3.2 km/h = 53.33 m/min -> VO2 = 0.1*53.33 + 3.5 = 8.833 ml/kg/min
    assert vo2_for_speed(3.2) == pytest.approx(8.833, abs=0.001)
    assert met_for_speed(3.2) == pytest.approx(8.833 / 3.5, abs=0.001)


def test_acsm_at_max_speed():
    # 6.4 km/h = 106.67 m/min -> VO2 = 14.167 -> ~4.05 MET
    assert vo2_for_speed(6.4) == pytest.approx(14.167, abs=0.001)


def test_kcal_per_minute_formula():
    # VO2 8.833, 75 kg: 8.833 * 75 / 200 = 3.3125
    assert kcal_per_minute(3.2, 75.0) == pytest.approx(3.3125, abs=0.001)


def test_tracker_accumulates():
    tr = CalorieTracker(weight_kg=75.0)
    tr.add_sample(3.2, 60)  # one minute at 3.2 km/h
    assert tr.total_kcal == pytest.approx(3.3125, abs=0.001)
    tr.add_sample(0.0, -5)  # invalid interval ignored
    assert tr.total_kcal == pytest.approx(3.3125, abs=0.001)
    tr.reset()
    assert tr.total_kcal == 0.0
