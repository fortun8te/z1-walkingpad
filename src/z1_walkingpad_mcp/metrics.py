"""Local health-metric estimation — the Z1 streams speed/distance/time/steps
but NOT calories, so we compute energy expenditure the same way fitness apps
do: the Compendium of Physical Activities MET values for level walking.

kcal/min = MET * 3.5 * weight_kg / 200
"""

from __future__ import annotations

import os

# MET by walking speed (km/h), level surface, Compendium of Physical Activities.
# Linear interpolation between points.
_MET_TABLE: list[tuple[float, float]] = [
    (0.0, 1.0),  # standing
    (1.6, 2.0),  # very slow walk
    (2.5, 2.8),
    (3.2, 3.0),
    (4.0, 3.5),
    (4.8, 3.8),
    (5.5, 4.3),
    (6.4, 5.0),  # Z1 max speed
]

DEFAULT_WEIGHT_KG = 75.0


def configured_weight_kg() -> float:
    raw = os.environ.get("Z1_WEIGHT_KG")
    if raw:
        try:
            return float(raw)
        except ValueError:
            pass
    return DEFAULT_WEIGHT_KG


def met_for_speed(kmh: float) -> float:
    if kmh <= _MET_TABLE[0][0]:
        return _MET_TABLE[0][1]
    for (s0, m0), (s1, m1) in zip(_MET_TABLE, _MET_TABLE[1:]):
        if kmh <= s1:
            frac = (kmh - s0) / (s1 - s0)
            return m0 + frac * (m1 - m0)
    return _MET_TABLE[-1][1]


def kcal_per_minute(kmh: float, weight_kg: float) -> float:
    return met_for_speed(kmh) * 3.5 * weight_kg / 200


class CalorieTracker:
    """Integrates calorie burn from a stream of speed samples."""

    def __init__(self, weight_kg: float | None = None) -> None:
        self.weight_kg = weight_kg if weight_kg is not None else configured_weight_kg()
        self.total_kcal = 0.0

    def add_sample(self, speed_kmh: float, elapsed_s: float) -> None:
        """Credit burn for elapsed_s spent at speed_kmh."""
        if elapsed_s <= 0:
            return
        self.total_kcal += kcal_per_minute(speed_kmh, self.weight_kg) * (elapsed_s / 60)

    def reset(self) -> None:
        self.total_kcal = 0.0
