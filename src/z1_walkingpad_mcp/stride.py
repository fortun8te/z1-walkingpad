"""Self-calibrating step estimator.

Research (Beevi et al.; Kowalski review) shows consumer step counters
degrade badly at slow walking speeds — exactly the under-desk range. But
the pad's DISTANCE is mechanically exact (belt revolutions). So:

- at >= TRUST_SPEED_KMH we trust the pad's step count and use it to learn
  the user's personal stride as a function of speed: stride = d/steps
- below it, steps are estimated as distance / stride(speed), with the
  learned curve interpolated between calibrated buckets

Persistence: ~/.z1-walkingpad/stride.json (bucket totals, survives restarts).
"""

from __future__ import annotations

import json
import os
from pathlib import Path

TRUST_SPEED_KMH = 3.0
# minimum accumulated distance in a bucket before it's considered calibrated
MIN_BUCKET_DISTANCE_M = 50.0

STATE_FILE = Path(os.environ.get("Z1_SESSIONS_DIR", Path.home() / ".z1-walkingpad")) / "stride.json"


def _bucket(speed_kmh: float) -> float:
    return round(int(speed_kmh * 2) / 2, 1)  # 0.5 km/h buckets


class StrideLearner:
    def __init__(self, state_file: Path = STATE_FILE) -> None:
        self.state_file = state_file
        # bucket -> [total_distance_m, total_steps]
        self._buckets: dict[float, list[float]] = {}
        self._load()

    def _load(self) -> None:
        try:
            raw = json.loads(self.state_file.read_text())
            self._buckets = {float(k): [float(v[0]), float(v[1])] for k, v in raw.items()}
        except (OSError, json.JSONDecodeError, KeyError, IndexError, ValueError):
            self._buckets = {}

    def _save(self) -> None:
        try:
            self.state_file.parent.mkdir(parents=True, exist_ok=True)
            self.state_file.write_text(json.dumps(self._buckets))
        except OSError:
            pass

    @property
    def calibrated(self) -> bool:
        return any(d >= MIN_BUCKET_DISTANCE_M for d, _ in self._buckets.values())

    def learn(self, distance_m: float, steps: float, speed_kmh: float) -> None:
        """Feed a trusted-zone segment (call only at >= TRUST_SPEED_KMH)."""
        if speed_kmh < TRUST_SPEED_KMH or distance_m <= 0 or steps <= 0:
            return
        b = _bucket(speed_kmh)
        entry = self._buckets.setdefault(b, [0.0, 0.0])
        entry[0] += distance_m
        entry[1] += steps
        self._save()

    def stride_for(self, speed_kmh: float) -> float | None:
        """Stride (m/step) at a speed: bucket value, linear interpolation
        between neighbors, or nearest bucket. None if uncalibrated."""
        points = sorted(
            (b, d / s) for b, (d, s) in self._buckets.items() if d >= MIN_BUCKET_DISTANCE_M and s > 0
        )
        if not points:
            return None
        target = _bucket(speed_kmh)
        for b, stride in points:
            if b == target:
                return stride
        if target <= points[0][0]:
            return points[0][1]
        if target >= points[-1][0]:
            return points[-1][1]
        for (b0, s0), (b1, s1) in zip(points, points[1:]):
            if b0 <= target <= b1:
                frac = (target - b0) / (b1 - b0)
                return s0 + frac * (s1 - s0)
        return points[-1][1]
