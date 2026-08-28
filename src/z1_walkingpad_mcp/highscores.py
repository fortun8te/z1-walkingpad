"""Highscores & achievements — derived from recorded sessions, never stored separately.
Retains data on update: computed live from sessions, old files always decode."""

from __future__ import annotations

import json
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1


def _parse_day(ts: float) -> str:
    return datetime.fromtimestamp(ts, tz=timezone.utc).date().isoformat()


def _load_sessions(sessions_dir: Path) -> list[dict[str, Any]]:
    sessions: list[dict[str, Any]] = []
    if sessions_dir.exists():
        # Prefer session-*.json (governor finalized sessions)
        for p in sorted(sessions_dir.glob("session-*.json")):
            try:
                data = json.loads(p.read_text())
                sessions.append(data)
            except (OSError, ValueError, json.JSONDecodeError):
                continue
        # Fallback: sessions.jsonl (legacy CLI/Governor stop)
        alt = Path.home() / ".z1-walkingpad" / "sessions.jsonl"
        if alt.exists() and not sessions:
            try:
                for line in alt.read_text().splitlines():
                    if line.strip():
                        try:
                            sessions.append(json.loads(line))
                        except (OSError, ValueError, json.JSONDecodeError):
                            continue
            except (OSError, ValueError, json.JSONDecodeError):
                pass
    # Also check Swift sessions.json for shared agent data (always, even if sessions_dir missing)
    swift_path = Path.home() / "Library/Application Support/Z1 WalkingPad/sessions.json"
    if swift_path.exists():
        try:
            swift_data = json.loads(swift_path.read_text())
            for entry in swift_data:
                # WalkSession shape: id, startedAt, endedAt, activeDurationS, distanceM, steps, caloriesKcal
                if "session_id" not in entry and "id" in entry:
                    # avoid duplicates by id
                    sid = entry.get("id")
                    if any(s.get("session_id") == sid for s in sessions):
                        continue
                    sessions.append({
                        "session_id": entry.get("id"),
                        "started_at": entry.get("startedAt"),
                        "ended_at": entry.get("endedAt"),
                        "duration_s": entry.get("activeDurationS"),
                        "active_duration_s": entry.get("activeDurationS"),
                        "distance_m": entry.get("distanceM"),
                        "steps": entry.get("steps"),
                        "calories_kcal": entry.get("caloriesKcal"),
                        "source": "swift",
                    })
        except (OSError, ValueError, json.JSONDecodeError) as e:
            print(f"swift load err {e}")
    return sessions


def _session_duration(s: dict[str, Any]) -> int:
    return int(s.get("active_duration_s") or s.get("duration_s") or 0)


def _session_distance(s: dict[str, Any]) -> float:
    return float(s.get("distance_m") or 0)


def _session_steps(s: dict[str, Any]) -> int:
    return int(s.get("steps") or 0)


def _session_kcal(s: dict[str, Any]) -> float:
    return float(s.get("calories_kcal") or s.get("calories") or 0)


def compute_highscores(sessions_dir: Path | None = None) -> dict[str, Any]:
    sessions_dir = Path(sessions_dir) if sessions_dir else Path.home() / ".z1-walkingpad" / "sessions"
    sessions = _load_sessions(sessions_dir)
    if not sessions:
        return {
            "schema_version": SCHEMA_VERSION,
            "total_walks": 0,
            "total_distance_m": 0,
            "total_steps": 0,
            "total_kcal": 0.0,
            "total_duration_s": 0,
            "longest_walk": None,
            "farthest_walk": None,
            "most_steps_walk": None,
            "most_kcal_walk": None,
            "most_steps_day": None,
            "most_kcal_day": None,
            "most_distance_day": None,
            "longest_day": None,
            "streak_days": 0,
            "best_streak_days": 0,
            "daily_aggregates": [],
        }

    def best(key):
        return max(sessions, key=key) if sessions else None

    longest = best(_session_duration)
    farthest = best(_session_distance)
    most_steps = best(_session_steps)
    most_kcal = best(_session_kcal)

    # Daily aggregates
    by_day: dict[str, dict[str, Any]] = defaultdict(lambda: {"day": "", "walks": 0, "active_duration_s": 0, "distance_m": 0, "steps": 0, "calories_kcal": 0.0})
    for s in sessions:
        raw = s.get("started_at")
        try:
            if isinstance(raw, (int, float)):
                day = _parse_day(float(raw))
            elif isinstance(raw, str):
                # isoformat
                day = raw[:10]
            else:
                day = _parse_day(float(s.get("ended_at") or 0))
        except (OSError, ValueError, json.JSONDecodeError):
            continue
        agg = by_day[day]
        agg["day"] = day
        agg["walks"] += 1
        agg["active_duration_s"] += _session_duration(s)
        agg["distance_m"] += _session_distance(s)
        agg["steps"] += _session_steps(s)
        agg["calories_kcal"] += _session_kcal(s)

    daily = sorted(by_day.values(), key=lambda d: d["day"])
    most_steps_day = max(daily, key=lambda d: d["steps"]) if daily else None
    most_kcal_day = max(daily, key=lambda d: d["calories_kcal"]) if daily else None
    most_dist_day = max(daily, key=lambda d: d["distance_m"]) if daily else None
    longest_day = max(daily, key=lambda d: d["active_duration_s"]) if daily else None

    # Streaks
    from datetime import date
    dates = sorted({d["day"] for d in daily})
    best_streak = 0
    cur = 0
    prev = None
    for ds in dates:
        try:
            cur_date = date.fromisoformat(ds)
        except (OSError, ValueError, json.JSONDecodeError):
            continue
        if prev and (cur_date - prev).days == 1:
            cur += 1
        else:
            cur = 1
        best_streak = max(best_streak, cur)
        prev = cur_date
    # current streak ending today
    today_str = datetime.now(timezone.utc).date().isoformat()
    streak = 0
    cursor = today_str
    date_set = set(dates)
    while cursor in date_set:
        streak += 1
        try:
            d = date.fromisoformat(cursor)
            from datetime import timedelta
            cursor = (d - timedelta(days=1)).isoformat()
        except (OSError, ValueError, json.JSONDecodeError):
            break

    return {
        "schema_version": SCHEMA_VERSION,
        "total_walks": len(sessions),
        "total_distance_m": int(sum(_session_distance(s) for s in sessions)),
        "total_steps": int(sum(_session_steps(s) for s in sessions)),
        "total_kcal": round(sum(_session_kcal(s) for s in sessions), 1),
        "total_duration_s": int(sum(_session_duration(s) for s in sessions)),
        "longest_walk": longest,
        "farthest_walk": farthest,
        "most_steps_walk": most_steps,
        "most_kcal_walk": most_kcal,
        "most_steps_day": most_steps_day,
        "most_kcal_day": most_kcal_day,
        "most_distance_day": most_dist_day,
        "longest_day": longest_day,
        "streak_days": streak,
        "best_streak_days": best_streak,
        "daily_aggregates": daily[-30:],
    }


ACHIEVEMENTS = [
    ("first_walk", "First Steps", "👟", lambda hs, s: hs["total_walks"] >= 1, lambda hs, s: min(1, hs["total_walks"] / 1)),
    ("walk_10", "10 Walks", "🔟", lambda hs, s: hs["total_walks"] >= 10, lambda hs, s: min(1, hs["total_walks"] / 10)),
    ("walk_50", "50 Walks", "⭐️", lambda hs, s: hs["total_walks"] >= 50, lambda hs, s: min(1, hs["total_walks"] / 50)),
    ("walk_100", "100 Walks", "💯", lambda hs, s: hs["total_walks"] >= 100, lambda hs, s: min(1, hs["total_walks"] / 100)),
    ("distance_100km", "100 km", "🗺️", lambda hs, s: hs["total_distance_m"] >= 100_000, lambda hs, s: min(1, hs["total_distance_m"] / 100_000)),
    ("distance_500km", "500 km", "🌍", lambda hs, s: hs["total_distance_m"] >= 500_000, lambda hs, s: min(1, hs["total_distance_m"] / 500_000)),
    ("steps_5k_day", "5K Day", "👣", lambda hs, s: (hs["most_steps_day"] or {}).get("steps", 0) >= 5000, lambda hs, s: min(1, (hs["most_steps_day"] or {}).get("steps", 0) / 5000)),
    ("steps_8k_day", "8K Day", "🔥", lambda hs, s: (hs["most_steps_day"] or {}).get("steps", 0) >= 8000, lambda hs, s: min(1, (hs["most_steps_day"] or {}).get("steps", 0) / 8000)),
    ("steps_10k_day", "10K Day", "⚡️", lambda hs, s: (hs["most_steps_day"] or {}).get("steps", 0) >= 10000, lambda hs, s: min(1, (hs["most_steps_day"] or {}).get("steps", 0) / 10000)),
    ("steps_15k_day", "15K Day", "🚀", lambda hs, s: (hs["most_steps_day"] or {}).get("steps", 0) >= 15000, lambda hs, s: min(1, (hs["most_steps_day"] or {}).get("steps", 0) / 15000)),
    ("kcal_200_day", "200 kcal Day", "🍎", lambda hs, s: (hs["most_kcal_day"] or {}).get("calories_kcal", 0) >= 200, lambda hs, s: min(1, (hs["most_kcal_day"] or {}).get("calories_kcal", 0) / 200)),
    ("kcal_500_day", "500 kcal Day", "🔥", lambda hs, s: (hs["most_kcal_day"] or {}).get("calories_kcal", 0) >= 500, lambda hs, s: min(1, (hs["most_kcal_day"] or {}).get("calories_kcal", 0) / 500)),
    ("hour_walk", "Hour Walker", "⏱️", lambda hs, s: (hs["longest_walk"] or {}).get("active_duration_s", hs["longest_walk"].get("duration_s", 0) if hs["longest_walk"] else 0) >= 3600 if hs["longest_walk"] else False, lambda hs, s: min(1, (hs["longest_walk"] or {}).get("active_duration_s", 0) / 3600 if hs["longest_walk"] else 0)),
    ("two_hour_walk", "Endurance", "🏔️", lambda hs, s: (hs["longest_walk"] or {}).get("active_duration_s", 0) >= 7200 if hs["longest_walk"] else False, lambda hs, s: min(1, (hs["longest_walk"] or {}).get("active_duration_s", 0) / 7200 if hs["longest_walk"] else 0)),
    ("streak_3", "3-Day Streak", "📅", lambda hs, s: hs["best_streak_days"] >= 3, lambda hs, s: min(1, hs["best_streak_days"] / 3)),
    ("streak_7", "Week Streak", "📆", lambda hs, s: hs["best_streak_days"] >= 7, lambda hs, s: min(1, hs["best_streak_days"] / 7)),
    ("streak_30", "Month Streak", "🏆", lambda hs, s: hs["best_streak_days"] >= 30, lambda hs, s: min(1, hs["best_streak_days"] / 30)),
]


def compute_achievements(sessions_dir: Path | None = None, highscores: dict | None = None) -> list[dict[str, Any]]:
    sessions_dir = Path(sessions_dir) if sessions_dir else Path.home() / ".z1-walkingpad" / "sessions"
    if highscores is None:
        highscores = compute_highscores(sessions_dir)
    sessions = _load_sessions(sessions_dir)
    out = []
    for key, title, emoji, cond, prog in ACHIEVEMENTS:
        try:
            unlocked = bool(cond(highscores, sessions))
            p = float(prog(highscores, sessions)) if not unlocked else 1.0
        except (OSError, ValueError, json.JSONDecodeError):
            unlocked = False
            p = 0.0
        out.append({"id": key, "title": title, "emoji": emoji, "unlocked": unlocked, "progress": round(min(1, max(0, p)), 3)})
    # Early bird / night owl need session time inspection
    try:
        from datetime import datetime
        has_early = any(datetime.fromisoformat(str(s.get("started_at") or s.get("ended_at") or "")[:19]).hour < 7 for s in sessions if s.get("started_at"))
        has_night = any(datetime.fromisoformat(str(s.get("started_at") or s.get("ended_at") or "")[:19]).hour >= 22 for s in sessions if s.get("started_at"))
    except (ValueError, OSError):
        has_early = has_night = False
    out.append({"id": "early_bird", "title": "Early Bird", "emoji": "🌅", "unlocked": has_early, "progress": 1 if has_early else 0})
    out.append({"id": "night_owl", "title": "Night Owl", "emoji": "🌙", "unlocked": has_night, "progress": 1 if has_night else 0})
    return out


def export_agent_data(sessions_dir: Path | None = None) -> dict[str, Any]:
    sessions_dir = Path(sessions_dir) if sessions_dir else Path.home() / ".z1-walkingpad" / "sessions"
    hs = compute_highscores(sessions_dir)
    ach = compute_achievements(sessions_dir, hs)
    sessions = _load_sessions(sessions_dir)
    return {
        "schema_version": SCHEMA_VERSION,
        "generated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "sessions_count": len(sessions),
        "sessions": sessions[-50:],
        "highscores": hs,
        "achievements": ach,
        "daily_aggregates": hs.get("daily_aggregates", []),
    }


def write_agent_export(sessions_dir: Path | None = None) -> Path | None:
    sessions_dir = Path(sessions_dir) if sessions_dir else Path.home() / ".z1-walkingpad" / "sessions"
    data = export_agent_data(sessions_dir)
    # Write to Python dir
    out = sessions_dir.parent / "agent-data.json"
    try:
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(data, indent=2))
    except OSError:
        pass
    # Mirror to Swift location for shared view
    alt = Path.home() / "Library/Application Support/Z1 WalkingPad/agent-data.json"
    try:
        alt.parent.mkdir(parents=True, exist_ok=True)
        alt.write_text(json.dumps(data, indent=2))
    except OSError:
        pass
    return out
