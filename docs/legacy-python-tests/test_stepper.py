from z1_walkingpad_mcp.models import StepSource
from z1_walkingpad_mcp.stepper import StepEstimator
from z1_walkingpad_mcp.stride import StrideLearner


def make(tmp_path):
    learner = StrideLearner(state_file=tmp_path / "stride.json")
    return learner, StepEstimator(learner)


def test_trusted_zone_learning(tmp_path):
    _, est = make(tmp_path)
    delta, source = est.feed(None, None, 10.0, 10, 4.0, None, 10)
    assert delta == 0 and source == StepSource.UNKNOWN
    distance = 10.0
    steps = 10
    elapsed = 10
    for _ in range(45):
        prev_distance, prev_steps, prev_elapsed = distance, steps, elapsed
        distance += 3
        steps += 4
        elapsed += 3
        delta, _ = est.feed(
            prev_distance, prev_steps, distance, steps, 4.0,
            prev_elapsed, elapsed, 4.0,
        )
        assert delta == 4
    assert est.calibrated


def test_slow_estimation_calibrated(tmp_path):
    learner, est = make(tmp_path)
    for _ in range(3):
        learner.learn(40, 50, 4.0)
    assert est.calibrated
    delta, source = est.feed(100.0, 100, 105.0, 101, 2.0)
    assert source == StepSource.CALIBRATED
    assert delta > 0


def test_outlier_rejected(tmp_path):
    learner, est = make(tmp_path)
    est.feed(None, None, 100.0, 10, 4.0)
    assert len(learner._buckets) == 0


def test_counter_reset(tmp_path):
    _, est = make(tmp_path)
    delta, source = est.feed(50.0, 60, 40.0, 55, 4.0)
    assert delta == 0 and source == StepSource.UNKNOWN


def test_raw_steps_not_dropped_when_distance_counter_stalls(tmp_path):
    _, est = make(tmp_path)
    delta, source = est.feed(10.0, 20, 10.0, 22, 4.0, 10, 11, 4.0)
    assert delta == 2
    assert source == StepSource.RAW


def test_sparse_packet_is_ignored(tmp_path):
    _, est = make(tmp_path)
    delta, source = est.feed(100.0, 100, None, None, 4.0)
    assert delta == 0
    assert source == StepSource.UNKNOWN
