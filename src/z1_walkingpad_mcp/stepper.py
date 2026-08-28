from __future__ import annotations

from .models import StepSource
from .stride import TRUST_SPEED_KMH, StrideLearner, _bucket

WINDOW_SECONDS = 12.0
MAX_WINDOW_SPEED_SPREAD_KMH = 0.15


class StepEstimator:
    def __init__(self, learner: StrideLearner | None = None) -> None:
        self.learner = learner if learner is not None else StrideLearner()
        self._reset_window()

    def _reset_window(self) -> None:
        self._window_bucket: float | None = None
        self._window_distance = 0.0
        self._window_steps = 0.0
        self._window_seconds = 0.0
        self._window_speed_min = float("inf")
        self._window_speed_max = float("-inf")
        self._window_speed_seconds = 0.0

    def _learn_interval(self, distance: float, steps: float, seconds: float, speed: float) -> None:
        bucket = _bucket(speed)
        stable = (
            seconds > 0
            and seconds <= 5
            and distance >= 0
            and steps >= 0
            and speed >= TRUST_SPEED_KMH
        )
        if not stable or (self._window_bucket is not None and bucket != self._window_bucket):
            self._reset_window()
        if not stable:
            return
        self._window_bucket = bucket
        self._window_distance += distance
        self._window_steps += steps
        self._window_seconds += seconds
        self._window_speed_min = min(self._window_speed_min, speed)
        self._window_speed_max = max(self._window_speed_max, speed)
        self._window_speed_seconds += speed * seconds
        if self._window_speed_max - self._window_speed_min > MAX_WINDOW_SPEED_SPREAD_KMH:
            self._reset_window()
            return
        if self._window_seconds >= WINDOW_SECONDS:
            avg_speed = self._window_speed_seconds / self._window_seconds
            self.learner.learn(self._window_distance, self._window_steps, avg_speed)
            self._reset_window()

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
        prev_elapsed_s: float | None = None,
        cur_elapsed_s: float | None = None,
        interval_speed_kmh: float | None = None,
    ) -> tuple[float, StepSource]:
        if prev_distance_m is None or prev_steps is None or cur_distance_m is None or cur_steps is None:
            self._reset_window()
            return 0.0, StepSource.UNKNOWN

        d_dist = cur_distance_m - prev_distance_m
        d_steps = cur_steps - prev_steps

        reset = (
            prev_distance_m is not None
            and cur_distance_m is not None
            and cur_distance_m < prev_distance_m
        ) or (prev_steps is not None and cur_steps is not None and cur_steps < prev_steps)
        if reset:
            self._reset_window()
            return 0.0, StepSource.UNKNOWN

        speed = interval_speed_kmh if interval_speed_kmh is not None else (speed_kmh or 0.0)
        trusted = speed >= TRUST_SPEED_KMH

        if trusted:
            elapsed = (
                cur_elapsed_s - prev_elapsed_s
                if prev_elapsed_s is not None and cur_elapsed_s is not None
                else 1.0
            )
            self._learn_interval(d_dist, float(d_steps), elapsed, speed)
            source = StepSource.CALIBRATED if self.learner.calibrated else StepSource.RAW
            # Raw steps are authoritative in the trusted zone even on packets
            # where the integer-metre distance counter has not advanced.
            return float(max(d_steps, 0)), source

        if d_dist <= 0:
            stride = self.learner.stride_for(speed)
            return (0.0, StepSource.CALIBRATED) if stride is not None else (
                float(max(d_steps, 0)), StepSource.ESTIMATED
            )

        self._reset_window()
        stride = self.learner.stride_for(speed)
        if stride is not None:
            return d_dist / stride, StepSource.CALIBRATED
        return float(max(d_steps, 0)), StepSource.ESTIMATED
