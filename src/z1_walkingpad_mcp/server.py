"""Read-only WalkingPad stats. Run with python -m z1_walkingpad_mcp.server."""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
from datetime import date, datetime, time, timedelta, timezone
from pathlib import Path

# The MCP SDK is imported only by the process that serves it (see `run`), so the
# data functions below can be read and tested without it installed.


def _root() -> Path:
    """Resolve on each read so a running MCP sees a newly created app folder."""
    if env := os.environ.get("Z1_SESSIONS_DIR"):
        # An explicit source stays authoritative while temporarily unavailable;
        # falling back would silently return another user's/default history.
        return Path(env).expanduser()
    return Path.home() / "Library/Application Support/Z1 WalkingPad"


def _j(name: str) -> dict | list | None:
    try:
        return json.loads((_root() / name).read_text())
    except (OSError, UnicodeError, json.JSONDecodeError, TypeError):
        return None


def _sessions() -> list[dict]:
    raw = _j("sessions.json")
    if not isinstance(raw, list):
        return []
    # Match the app's first-record-wins recovery of duplicate session IDs.
    seen = set()
    result = []
    for item in raw:
        if not isinstance(item, dict):
            continue
        identifier = item.get("id")
        if _native_record(item):
            if identifier in seen:
                continue
            seen.add(identifier)
        result.append(item)
    return result


def _native_record(item: dict) -> bool:
    """Only decodable app records own an ID during duplicate recovery."""
    return (
        isinstance(item.get("id"), str)
        and all(_parse(item.get(key)) is not None for key in ("startedAt", "endedAt"))
        and all(type(item.get(key)) is int and -sys.maxsize - 1 <= item[key] <= sys.maxsize
                for key in ("distanceM", "activeDurationS", "steps"))
        and type(item.get("caloriesKcal")) in (int, float)
        and abs(item["caloriesKcal"]) <= sys.float_info.max
        and type(item.get("exportedToHealth")) is bool
    )


def _parse(timestamp) -> datetime | None:
    """An app timestamp as an aware datetime, or None. Naive means local."""
    try:
        return datetime.fromisoformat(timestamp.replace("Z", "+00:00")).astimezone()
    except (AttributeError, ValueError, TypeError, OverflowError, OSError):
        return None


def _local_day(timestamp) -> str:
    """The calendar day a timestamp falls on in the Mac's own time zone.

    Sessions are stored in UTC ("...Z"). Comparing that text with today's local
    date puts a walk at 00:30 Amsterdam time on the previous day.
    """
    parsed = _parse(timestamp)
    return parsed.date().isoformat() if parsed else ""


def _int(value) -> int:
    try:
        return min(sys.maxsize, max(0, int(value or 0)))
    except (TypeError, ValueError, OverflowError):
        return 0


def _float(value) -> float:
    try:
        result = float(value or 0)
        return max(0.0, result) if math.isfinite(result) else 0.0
    except (TypeError, ValueError, OverflowError):
        return 0.0


def _row(session: dict) -> dict:
    return {
        "d": _local_day(session.get("startedAt")),
        "m": _int(session.get("distanceM")),
        "s": _int(session.get("activeDurationS")),
        "steps": _int(session.get("steps")),
        "kcal": round(_float(session.get("caloriesKcal")), 1),
    }


def _round_half_up(value: float) -> int:
    return math.floor(value + 0.5)


def _share_of_day(session: dict, first: datetime, last: datetime) -> dict | None:
    """The part of a session that falls inside [first, last), as a row.

    The app stores no pause times, so a walk that crosses midnight is split in
    proportion to wall time, with the same cumulative rounding the app uses, so
    both halves add up to the whole and agree with the app's own day totals.
    """
    start = _parse(session.get("startedAt"))
    if start is None:
        return None
    end = _parse(session.get("endedAt"))
    if end is None:
        try:
            end = start + timedelta(seconds=max(1, _int(session.get("activeDurationS"))))
        except OverflowError:
            return None
    wall = max(1.0, (end - start).total_seconds())
    lower = min(1.0, max(0.0, (first - start).total_seconds() / wall))
    upper = min(1.0, max(0.0, (last - start).total_seconds() / wall))
    if upper <= lower:
        return None

    def portion(value) -> int:
        number = _int(value)
        return _round_half_up(number * upper) - _round_half_up(number * lower)

    return {
        "m": portion(session.get("distanceM")),
        "s": portion(session.get("activeDurationS")),
        "steps": portion(session.get("steps")),
        "kcal": _float(session.get("caloriesKcal")) * (upper - lower),
    }


def _fresh_live() -> dict | None:
    """The app's live.json, or None when it is missing or older than 90 s."""
    data = _j("live.json")
    if not isinstance(data, dict) or type(data.get("schema")) is not int or data["schema"] != 1:
        return None
    try:
        updated = datetime.fromisoformat(data["updatedAt"].replace("Z", "+00:00"))
        if abs((datetime.now(timezone.utc) - updated).total_seconds()) > 90:
            return None
    except (KeyError, AttributeError, TypeError, ValueError, OverflowError):
        return None
    return data


def _live() -> dict | None:
    data = _fresh_live()
    if data is None:
        return None
    return {
        "kmh": _float(data.get("speedKmh")),
        "on": bool(data.get("beltRunning")),
        "m": _int(data.get("distanceM")),
        "s": _int(data.get("elapsedSec")),
        "steps": _int(data.get("steps")),
        "kcal": (round(_float(data["caloriesKcal"]), 1)
                 if data.get("caloriesKcal") is not None else None),
        "connected": bool(data.get("connected")),
    }


def _sum(rows: list[dict]) -> dict:
    return {
        "m": sum(row["m"] for row in rows),
        "s": sum(row["s"] for row in rows),
        "steps": sum(row["steps"] for row in rows),
        "kcal": round(min(sys.float_info.max, sum(row["kcal"] for row in rows)), 1),
    }


def _today() -> dict:
    today = date.today()  # noqa: DTZ011 (the Mac's local day is the point)
    day = today.isoformat()
    first = datetime.combine(today, time.min).astimezone()
    last = datetime.combine(today + timedelta(days=1), time.min).astimezone()
    live = _fresh_live()
    if live and (live.get("todayDate") or _local_day(live.get("updatedAt"))) != day:
        live = None
    # A complete current snapshot already includes saved and unsaved walks.
    # Avoid reading and aggregating all history only to overwrite it below.
    complete = live is not None and all(key in live for key in (
        "todayDistanceM", "todayMinutes", "todaySteps", "todayKcal"
    ))
    rows = [] if complete else [
        row for row in (_share_of_day(session, first, last) for session in _sessions()) if row
    ]
    total = _sum(rows)
    total["d"] = day
    # The app labels its totals with the day they belong to. Just after
    # midnight it can still be publishing yesterday's, in a file written today.
    if live:
        # App total includes completed walks and the open walk.
        if "todayDistanceM" in live:
            total["m"] = _int(live["todayDistanceM"])
        if "todayMinutes" in live:
            minutes = _float(live["todayMinutes"])
            total["s"] = (sys.maxsize if minutes >= sys.maxsize / 60
                          else round(minutes * 60))
        if "todaySteps" in live:
            total["steps"] = _int(live["todaySteps"])
        if "todayKcal" in live:
            total["kcal"] = round(_float(live["todayKcal"]), 1)
        if live.get("beltRunning"):
            total["kmh"] = _float(live.get("speedKmh"))
    return total


async def z1(q: str = "today") -> dict:
    """Walk stats. q=today (default)|live|all|list. Read-only."""
    q = (q or "today").strip().lower()
    if q in ("", "today", "t"):
        return _today()
    if q in ("live", "l"):
        return _live() or {}
    rows = [_row(session) for session in _sessions()]
    if q in ("list", "recent", "r"):
        return {"list": rows[-5:]}
    total = _sum(rows)
    total["n"] = len(rows)
    return total


def build_server():
    from mcp.server.mcpserver import MCPServer

    server = MCPServer("z1")
    server.tool()(z1)
    return server


def run() -> None:
    parser = argparse.ArgumentParser(description="Read-only Z1 WalkingPad stats MCP server. Control the pad in the macOS app.")
    parser.parse_args()
    build_server().run()


if __name__ == "__main__":
    run()
