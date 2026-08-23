from __future__ import annotations

from .config import GovernorConfig


def _round_01(value: float) -> float:
    return round(value * 10) / 10


class SpeedRamp:
    def __init__(self, config: GovernorConfig) -> None:
        self.config = config

    def clamp(self, speed: float, floor: float = 0.0) -> float:
        clamped = min(max(_round_01(speed), floor), self.config.max_speed_kmh)
        return _round_01(clamped)

    def next_step(self, current: float, target: float) -> float:
        target = self.clamp(target)
        current = self.clamp(current)
        step = self.config.ramp_step_kmh
        if current < target:
            return self.clamp(min(current + step, target))
        if current > target:
            return self.clamp(max(current - step, target))
        return current
