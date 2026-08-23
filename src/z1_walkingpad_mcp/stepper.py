from __future__ import annotations

from .models import StepSource
from .stride import TRUST_SPEED_KMH, StrideLearner

MIN_STRIDE_M = 0.30
MAX_STRIDE_M = 1.50


class StepEstimator:
    def __init__(self, learner: StrideLearner | None = None) -> None:
        self.learner = learner if learner is not None else StrideLearner()

    @property
    def calibrated(self) -> bool:
        return self.learner.calibrated

    def feed(
        self,
        prev_distance_m: float | None,
        prev_steps: int | None,
        cur_distance_m: float | None,
        cur_steps: int | None,
        speed_kmh: float | None,
    ) -> tuple[float, StepSource]:
        d_dist = (cur_distance_m or 0.0) - (prev_distance_m or 0.0)
        d_steps = (cur_steps or 0) - (prev_steps or 0)

        reset = (
            prev_distance_m is not None
            and cur_distance_m is not None
            and cur_distance_m < prev_distance_m
        ) or (prev_steps is not None and cur_steps is not None and cur_steps < prev_steps)
        if reset:
            return 0.0, StepSource.UNKNOWN

        speed = speed_kmh or 0.0
        trusted = speed >= TRUST_SPEED_KMH

        if trusted and d_dist > 0 and d_steps > 0:
            stride = d_dist / d_steps
            if MIN_STRIDE_M <= stride <= MAX_STRIDE_M:
                self.learner.learn(d_dist, d_steps, speed)
                source = StepSource.CALIBRATED if self.learner.calibrated else StepSource.RAW
                return float(d_steps), source

        if d_dist <= 0:
            return 0.0, StepSource.UNKNOWN

        stride = self.learner.stride_for(speed)
        if stride is not None:
            return d_dist / stride, StepSource.CALIBRATED
        return float(max(d_steps, 0)), StepSource.ESTIMATED
