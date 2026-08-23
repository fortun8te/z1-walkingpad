from z1_walkingpad_mcp.models import StepSource
from z1_walkingpad_mcp.stepper import StepEstimator
from z1_walkingpad_mcp.stride import StrideLearner


def make(tmp_path):
    learner = StrideLearner(state_file=tmp_path / "stride.json")
    return learner, StepEstimator(learner)


def test_trusted_zone_learning(tmp_path):
    _, est = make(tmp_path)
    delta, source = est.feed(None, None, 10.0, 10, 4.0)
    assert delta == 10 and source == StepSource.RAW
    for i in range(1, 12):
        est.feed(i * 10 - 10, i * 10 - 10 if i > 1 else 10, i * 10, i * 10 + 10, 4.0)
    assert est.calibrated


def test_slow_estimation_calibrated(tmp_path):
    _, est = make(tmp_path)
    for i in range(1, 12):
        est.feed(i * 20 - 20, (i * 20 - 20) // 2 or 10, i * 20, i * 20 // 2 + 10, 4.0)
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
