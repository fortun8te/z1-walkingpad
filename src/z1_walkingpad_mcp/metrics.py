"""Local health-metric estimation — the Z1 streams speed/distance/time/steps
but NOT calories, so we compute energy expenditure with the **ACSM walking
metabolic equation** (level grade), the exercise-physiology standard:

    VO2 (ml/kg/min) = 0.1 * speed(m/min) + 3.5          (grade = 0)
    kcal/min        = VO2 * weight_kg / 200             (5 kcal per L O2)

Best validated for 50-100 m/min (~3-6 km/h); below that (our minimum is
1.6 km/h) expect somewhat larger error. Classic validation puts the standard
error around 2.0-2.6 ml/kg/min (~0.6-0.7 MET); a 2021 field comparison found
~13% overprediction for unloaded walking. This replaces the coarser
Compendium-of-METs bucket table, which research shows misclassifies
intensity near slow-walking speeds.

Sources: ACSM Guidelines for Exercise Testing and Prescription;
japplphysiol.00121.2021 (2021); pubmed 16095415; pubmed 35876127 (2022).
"""

from __future__ import annotations

import os

DEFAULT_WEIGHT_KG = 75.0

# resting component of the ACSM equation (3.5 ml/kg/min = 1 MET)
_RESTING_VO2 = 3.5
# walking economy: 0.1 ml/kg/min per m/min on level ground
_SPEED_COEFF = 0.1


def configured_weight_kg() -> float:
    raw = os.environ.get("Z1_WEIGHT_KG")
    if raw:
        try:
            return float(raw)
        except ValueError:
            pass
    return DEFAULT_WEIGHT_KG


def vo2_for_speed(kmh: float) -> float:
    """Gross VO2 (ml/kg/min) per the ACSM level-walking equation."""
    speed_m_per_min = max(0.0, kmh) * 1000 / 60
    return _SPEED_COEFF * speed_m_per_min + _RESTING_VO2


def met_for_speed(kmh: float) -> float:
    return vo2_for_speed(kmh) / _RESTING_VO2


def kcal_per_minute(kmh: float, weight_kg: float) -> float:
    return vo2_for_speed(kmh) * weight_kg / 200


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
