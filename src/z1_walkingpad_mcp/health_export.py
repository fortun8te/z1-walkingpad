"""Build conservative, validated records for the iPhone Health Shortcut."""

from __future__ import annotations

import math
import os
from datetime import datetime, timedelta, timezone


def _positive_env_number(name: str, default: float) -> float:
    try:
        value = float(os.environ.get(name, default))
    except (TypeError, ValueError):
        return default
    return value if math.isfinite(value) and value > 0 else default


def build_health_record(summary: dict, ended_at: float, session_id: str) -> dict | None:
    """Return a safe Health queue record, or ``None`` for junk sessions."""
    try:
        duration = int(summary.get("active_duration_s") or summary.get("duration_s") or 0)
        distance = float(summary.get("distance_m") or 0)
        steps = int(summary.get("steps") or 0)
        end = datetime.fromtimestamp(float(ended_at), tz=timezone.utc)
    except (TypeError, ValueError, OverflowError, OSError):
        return None
    min_active_s = int(_positive_env_number("Z1_HEALTH_MIN_ACTIVE_S", 600))
    min_distance_m = _positive_env_number("Z1_HEALTH_MIN_DISTANCE_M", 100)
    if (
        duration < min_active_s
        or duration > 86_400
        or distance < min_distance_m
        or distance > 200_000
        or steps < 0
        or not math.isfinite(distance)
        or distance / duration * 3.6 > 7.0
    ):
        return None
    raw_start = summary.get("started_at")
    try:
        start = datetime.fromtimestamp(float(raw_start), tz=timezone.utc) if raw_start else end - timedelta(seconds=duration)
    except (TypeError, ValueError, OverflowError, OSError):
        start = end - timedelta(seconds=duration)
    if start >= end:
        return None
    wall_duration = int((end - start).total_seconds())
    if wall_duration > 86_400 or duration > wall_duration + 5:
        return None
    return {
        "schema_version": 1,
        "session_id": session_id,
        "source": "z1-walkingpad",
        "started_at": start.isoformat().replace("+00:00", "Z"),
        "ended_at": end.isoformat().replace("+00:00", "Z"),
        "duration_s": duration,
        "wall_duration_s": wall_duration,
        "wall_duration_min": round(wall_duration / 60, 3),
        "distance_m": round(distance, 1),
        "steps": steps,
    }
