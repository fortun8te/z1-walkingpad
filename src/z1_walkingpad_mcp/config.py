from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Mapping


def _float(env: Mapping[str, str], key: str, default: float) -> float:
    raw = env.get(key)
    if raw is None or raw == "":
        return default
    return float(raw)


def _bool(env: Mapping[str, str], key: str) -> bool:
    return env.get(key, "").strip().lower() in {"1", "true"}


@dataclass(frozen=True)
class GovernorConfig:
    max_speed_kmh: float = 3.5
    default_speed_kmh: float = 3.5
    ramp_step_kmh: float = 0.1
    ramp_interval_s: float = 2.0
    stale_telemetry_s: float = 4.0
    step_off_timeout_s: float = 8.0
    command_timeout_s: float = 5.0
    motion_enabled: bool = False

    def validate(self) -> None:
        numeric = {
            "max_speed_kmh": self.max_speed_kmh,
            "default_speed_kmh": self.default_speed_kmh,
            "ramp_step_kmh": self.ramp_step_kmh,
            "ramp_interval_s": self.ramp_interval_s,
            "stale_telemetry_s": self.stale_telemetry_s,
            "step_off_timeout_s": self.step_off_timeout_s,
            "command_timeout_s": self.command_timeout_s,
        }
        for name, value in numeric.items():
            if value <= 0:
                raise ValueError(f"{name} must be > 0")
        if self.default_speed_kmh > self.max_speed_kmh:
            raise ValueError("default_speed_kmh must not exceed max_speed_kmh")
        if self.ramp_step_kmh > self.max_speed_kmh:
            raise ValueError("ramp_step_kmh must not exceed max_speed_kmh")

    @classmethod
    def from_env(cls, env: Mapping[str, str] = os.environ) -> GovernorConfig:
        cfg = cls(
            max_speed_kmh=_float(env, "Z1_GOVERNOR_MAX_SPEED_KMH", 3.5),
            default_speed_kmh=_float(env, "Z1_GOVERNOR_DEFAULT_SPEED_KMH", 3.5),
            ramp_step_kmh=_float(env, "Z1_GOVERNOR_RAMP_STEP_KMH", 0.1),
            ramp_interval_s=_float(env, "Z1_GOVERNOR_RAMP_INTERVAL_S", 2.0),
            stale_telemetry_s=_float(env, "Z1_STALE_TELEMETRY_S", 4.0),
            step_off_timeout_s=_float(env, "Z1_STEP_OFF_TIMEOUT_S", 8.0),
            command_timeout_s=_float(env, "Z1_COMMAND_TIMEOUT_S", 5.0),
            motion_enabled=_bool(env, "Z1_ENABLE_MOTION"),
        )
        cfg.validate()
        return cfg
