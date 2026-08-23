import pytest

from z1_walkingpad_mcp.config import GovernorConfig


def test_defaults():
    cfg = GovernorConfig()
    assert cfg.max_speed_kmh == 3.5
    assert cfg.motion_enabled is False
    cfg.validate()


def test_env_parsing():
    env = {
        "Z1_GOVERNOR_MAX_SPEED_KMH": "4.0",
        "Z1_GOVERNOR_DEFAULT_SPEED_KMH": "3.0",
        "Z1_ENABLE_MOTION": "TRUE",
    }
    cfg = GovernorConfig.from_env(env)
    assert cfg.max_speed_kmh == 4.0
    assert cfg.default_speed_kmh == 3.0
    assert cfg.motion_enabled is True


@pytest.mark.parametrize(
    "field,value",
    [
        ("max_speed_kmh", 0),
        ("ramp_interval_s", -1),
        ("stale_telemetry_s", 0),
    ],
)
def test_invalid_numeric(field, value):
    with pytest.raises(ValueError):
        GovernorConfig(**{field: value}).validate()


def test_default_exceeds_max():
    with pytest.raises(ValueError):
        GovernorConfig(default_speed_kmh=5.0, max_speed_kmh=3.5).validate()
