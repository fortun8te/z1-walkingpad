from z1_walkingpad_mcp.config import GovernorConfig
from z1_walkingpad_mcp.ramping import SpeedRamp


CFG = GovernorConfig(max_speed_kmh=3.5)


def test_clamp_rounds_to_tenth():
    assert SpeedRamp(CFG).clamp(2.34) == 2.3
    assert SpeedRamp(CFG).clamp(9.9) == 3.5
    assert SpeedRamp(CFG).clamp(-1) == 0.0


def test_ramp_up_sequence():
    ramp = SpeedRamp(CFG)
    seq = [ramp.next_step(c, 1.8) for c in [1.6, 1.7, 1.8]]
    assert seq == [1.7, 1.8, 1.8]


def test_ramp_down_and_cap():
    ramp = SpeedRamp(CFG)
    assert ramp.next_step(2.0, 1.6) == 1.9
    assert ramp.next_step(3.4, 9.9) == 3.5
