"""Unit tests for the local MET-based calorie estimation."""

import pytest

from z1_walkingpad_mcp.metrics import CalorieTracker, kcal_per_minute, met_for_speed


def test_met_standing():
    assert met_for_speed(0.0) == 1.0


def test_met_known_points():
    assert met_for_speed(3.2) == pytest.approx(3.0)
    assert met_for_speed(6.4) == pytest.approx(5.0)


def test_met_interpolation():
    # halfway between 3.2 (3.0) and 4.0 (3.5)
    assert met_for_speed(3.6) == pytest.approx(3.25)


def test_met_above_table_caps():
    assert met_for_speed(10.0) == 5.0


def test_kcal_per_minute_formula():
    # 3.0 MET, 75 kg: 3.0 * 3.5 * 75 / 200 = 3.9375
    assert kcal_per_minute(3.2, 75.0) == pytest.approx(3.9375)


def test_tracker_accumulates():
    tr = CalorieTracker(weight_kg=75.0)
    tr.add_sample(3.2, 60)  # one minute at 3.2 km/h
    assert tr.total_kcal == pytest.approx(3.9375)
    tr.add_sample(0.0, -5)  # invalid interval ignored
    assert tr.total_kcal == pytest.approx(3.9375)
    tr.reset()
    assert tr.total_kcal == 0.0
