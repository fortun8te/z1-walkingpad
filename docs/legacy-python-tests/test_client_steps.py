from z1_walkingpad_mcp import client as client_module
from z1_walkingpad_mcp.client import Z1Treadmill
from z1_walkingpad_mcp.stepper import StepEstimator
from z1_walkingpad_mcp.stride import StrideLearner


def frame(speed_kmh, distance_m, elapsed_s, steps):
    return bytes([0x04, 0x24]) + b"".join(
        (
            round(speed_kmh * 100).to_bytes(2, "little"),
            distance_m.to_bytes(3, "little"),
            elapsed_s.to_bytes(2, "little"),
            steps.to_bytes(2, "little"),
        )
    )


def test_client_keeps_sparse_counters_and_does_not_drop_steps(tmp_path, monkeypatch):
    monkeypatch.setattr(client_module, "CALORIE_STATE_FILE", tmp_path / "calorie.json")
    treadmill = Z1Treadmill()
    treadmill.stride = StrideLearner(tmp_path / "stride.json")
    treadmill.stepper = StepEstimator(treadmill.stride)

    treadmill._on_treadmill_data(None, bytearray(frame(4.0, 10, 10, 20)))
    assert treadmill.steps_display == 20

    # Speed-only sparse packet must not erase counters.
    treadmill._on_treadmill_data(None, bytearray([0x00, 0x00, 0x90, 0x01]))
    assert treadmill.status.distance_m == 10
    assert treadmill.status.steps == 20

    # The pad can report steps before its whole-metre distance ticks forward.
    treadmill._on_treadmill_data(None, bytearray(frame(4.0, 10, 11, 22)))
    assert treadmill.steps_display == 22
