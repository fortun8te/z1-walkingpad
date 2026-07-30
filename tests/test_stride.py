"""Unit tests for the self-calibrating stride estimator."""

import pytest

from z1_walkingpad_mcp.stride import TRUST_SPEED_KMH, StrideLearner


@pytest.fixture()
def learner(tmp_path):
    return StrideLearner(state_file=tmp_path / "stride.json")


def test_uncalibrated_returns_none(learner):
    assert not learner.calibrated
    assert learner.stride_for(2.0) is None


def test_ignores_slow_or_empty_segments(learner):
    learner.learn(100, 150, 2.0)  # below trust speed
    learner.learn(0, 100, 4.0)  # no distance
    learner.learn(100, 0, 4.0)  # no steps
    assert not learner.calibrated


def test_learn_and_bucket_readback(learner):
    learner.learn(120, 160, 3.5)  # stride 0.75 in the 3.5 bucket
    assert learner.calibrated
    assert learner.stride_for(3.5) == pytest.approx(0.75)


def test_interpolation_between_buckets(learner):
    learner.learn(140, 200, 3.0)  # 0.70 at 3.0
    learner.learn(160, 200, 4.0)  # 0.80 at 4.0
    assert learner.stride_for(3.5) == pytest.approx(0.75)


def test_extrapolation_uses_nearest(learner):
    learner.learn(140, 200, 3.0)
    assert learner.stride_for(1.6) == pytest.approx(0.70)
    assert learner.stride_for(6.4) == pytest.approx(0.70)


def test_min_distance_threshold(learner):
    learner.learn(30, 40, 3.5)  # below 50m minimum — not yet calibrated
    assert learner.stride_for(3.5) is None
    learner.learn(30, 40, 3.5)  # cumulative 60m — now calibrated
    assert learner.stride_for(3.5) == pytest.approx(60 / 80)


def test_persistence_roundtrip(tmp_path):
    path = tmp_path / "stride.json"
    a = StrideLearner(state_file=path)
    a.learn(120, 160, 3.5)
    b = StrideLearner(state_file=path)
    assert b.stride_for(3.5) == pytest.approx(0.75)


def test_trust_speed_value():
    assert TRUST_SPEED_KMH == 3.0
