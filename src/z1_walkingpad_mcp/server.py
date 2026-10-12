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
    paths = []
    if env := os.environ.get("Z1_SESSIONS_DIR"):
        paths.append(Path(env).expanduser())
    if sys.platform == "darwin":
        paths.append(Path.home() / "Library/Application Support/Z1 WalkingPad")
    paths.append(Path.home() / ".z1-walkingpad")
    return next(
        (path for path in paths if (path / "sessions.json").is_file() or (path / "live.json").is_file()),
        paths[0],
    )


def _j(name: str) -> dict | list | None:
    try:
        return json.loads((_root() / name).read_text())
    except (OSError, json.JSONDecodeError, TypeError):
        return None


def _sessions() -> list[dict]:
    raw = _j("sessions.json")
    return [item for item in raw if isinstance(item, dict)] if isinstance(raw, list) else []


def _parse(timestamp) -> datetime | None:
    """An app timestamp as an aware datetime, or None. Naive means local."""
    try:
        return datetime.fromisoformat(timestamp.replace("Z", "+00:00")).astimezone()
    except (AttributeError, ValueError, TypeError):
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
        return int(value or 0)
    except (TypeError, ValueError):
        return 0


def _float(value) -> float:
    try:
        return float(value or 0)
    except (TypeError, ValueError):
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
    end = _parse(session.get("endedAt")) or start + timedelta(
        seconds=max(1, _int(session.get("activeDurationS")))
    )
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
    data = _j("live.json")
    if not isinstance(data, dict):
        return None
    if data.get("schema") == 1:
        try:
            updated = datetime.fromisoformat(data["updatedAt"].replace("Z", "+00:00"))
            if abs((datetime.now(timezone.utc) - updated).total_seconds()) > 90:
                return None
        except (KeyError, AttributeError, TypeError, ValueError):
            return None
    else:
        timestamp = data.get("t")
        if not isinstance(timestamp, (int, float)) or datetime.now(timezone.utc).timestamp() - timestamp > 90:
            return None
    return data


def _live() -> dict | None:
    data = _fresh_live()
    if data is None:
        return None
    if data.get("schema") == 1:
        return {
            "kmh": data.get("speedKmh"),
            "on": bool(data.get("beltRunning")),
            "m": _int(data.get("distanceM")),
            "s": _int(data.get("elapsedSec")),
            "steps": _int(data.get("steps")),
            "kcal": (round(_float(data["caloriesKcal"]), 1)
                     if data.get("caloriesKcal") is not None else None),
            "connected": bool(data.get("connected")),
        }
    return {
        "kmh": data.get("kmh"),
        "on": bool(data.get("on")),
        "m": _int(data.get("m")),
        "s": _int(data.get("s")),
        "steps": _int(data.get("steps")),
        "kcal": round(_float(data.get("kcal")), 1),
    }


def _sum(rows: list[dict]) -> dict:
    return {
        "m": sum(row["m"] for row in rows),
        "s": sum(row["s"] for row in rows),
        "steps": sum(row["steps"] for row in rows),
        "kcal": round(sum(row["kcal"] for row in rows), 1),
    }


def _today() -> dict:
    today = date.today()  # noqa: DTZ011 (the Mac's local day is the point)
    day = today.isoformat()
    first = datetime.combine(today, time.min).astimezone()
    last = datetime.combine(today + timedelta(days=1), time.min).astimezone()
    rows = [row for row in (_share_of_day(session, first, last) for session in _sessions()) if row]
    total = _sum(rows)
    total["d"] = day
    live = _fresh_live()
    # The app labels its totals with the day they belong to. Just after
    # midnight it can still be publishing yesterday's, in a file written today.
    if live and live.get("schema") == 1 and (live.get("todayDate") or _local_day(live.get("updatedAt"))) == day:
        # App total includes completed walks and the open walk.
        total["m"] = _int(live.get("todayDistanceM"))
        total["s"] = round(_float(live.get("todayMinutes")) * 60)
        if "todaySteps" in live:
            total["steps"] = _int(live["todaySteps"])
        if "todayKcal" in live:
            total["kcal"] = round(_float(live["todayKcal"]), 1)
        if live.get("beltRunning"):
            total["kmh"] = live.get("speedKmh")
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
