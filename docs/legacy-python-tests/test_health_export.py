from datetime import datetime

from z1_walkingpad_mcp.health_export import build_health_record


def test_health_record_uses_real_wall_dates_and_omits_calories():
    record = build_health_record(
        {
            "duration_s": 1800,
            "active_duration_s": 1200,
            "started_at": 1_799_998_200,
            "distance_m": 1000,
            "steps": 700,
            "calories_kcal": 40,
        },
        1_800_000_000,
        "abc",
    )
    assert record is not None
    assert record["session_id"] == "abc"
    assert "active_calories_kcal" not in record
    start = datetime.fromisoformat(record["started_at"].replace("Z", "+00:00"))
    end = datetime.fromisoformat(record["ended_at"].replace("Z", "+00:00"))
    assert (end - start).total_seconds() == 1800
    assert record["duration_s"] == 1200
    assert record["wall_duration_s"] == 1800
    assert record["wall_duration_min"] == 30


def test_health_record_rejects_junk_sessions():
    assert build_health_record({}, 1_800_000_000, "empty") is None
    assert build_health_record(
        {"duration_s": 10, "distance_m": 1, "steps": 1, "calories_kcal": 1, "weight_kg_used": 80},
        1_800_000_000,
        "tiny",
    ) is None


def test_health_record_rejects_short_or_short_distance():
    assert build_health_record(
        {"active_duration_s": 599, "distance_m": 500, "steps": 600},
        1_800_000_000,
        "short-time",
    ) is None


def test_health_record_rejects_impossible_records():
    assert build_health_record(
        {"active_duration_s": 600, "distance_m": 5_000, "steps": 100},
        1_800_000_000,
        "too-fast",
    ) is None
    assert build_health_record(
        {
            "active_duration_s": 1_200,
            "started_at": 1_800_000_000 - 600,
            "distance_m": 1_000,
            "steps": 1_200,
        },
        1_800_000_000,
        "active-longer-than-wall",
    ) is None
    assert build_health_record(
        {"active_duration_s": 600, "distance_m": 99, "steps": 120},
        1_800_000_000,
        "short-distance",
    ) is None
