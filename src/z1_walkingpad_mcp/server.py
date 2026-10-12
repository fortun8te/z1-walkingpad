"""Read-only WalkingPad stats. Run with python -m z1_walkingpad_mcp.server."""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import date, datetime, timezone
from pathlib import Path

from mcp.server.mcpserver import MCPServer

mcp = MCPServer("z1")


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


def _local_day(timestamp: str) -> str:
    try:
        parsed = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
        return parsed.astimezone().date().isoformat()
    except (AttributeError, ValueError, TypeError):
        return ""


def _row(session: dict) -> dict:
    return {
        "d": _local_day(session.get("startedAt")),
        "m": int(session.get("distanceM") or 0),
        "s": int(session.get("activeDurationS") or 0),
        "steps": int(session.get("steps") or 0),
        "kcal": round(float(session.get("caloriesKcal") or 0), 1),
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
            "m": int(data.get("distanceM") or 0),
            "s": int(data.get("elapsedSec") or 0),
            "steps": int(data.get("steps") or 0),
            "kcal": (round(float(data["caloriesKcal"]), 1)
                     if data.get("caloriesKcal") is not None else None),
            "connected": bool(data.get("connected")),
        }
    return {
        "kmh": data.get("kmh"),
        "on": bool(data.get("on")),
        "m": int(data.get("m") or 0),
        "s": int(data.get("s") or 0),
        "steps": int(data.get("steps") or 0),
        "kcal": round(float(data.get("kcal") or 0), 1),
    }


def _sum(rows: list[dict]) -> dict:
    return {
        "m": sum(row["m"] for row in rows),
        "s": sum(row["s"] for row in rows),
        "steps": sum(row["steps"] for row in rows),
        "kcal": round(sum(row["kcal"] for row in rows), 1),
    }


def _today() -> dict:
    day = date.today().isoformat()
    rows = [_row(session) for session in _sessions()]
    total = _sum([row for row in rows if row["d"] == day])
    total["d"] = day
    live = _fresh_live()
    if live and live.get("schema") == 1 and _local_day(live.get("updatedAt")) == day:
        # App total includes completed walks and the open walk.
        total["m"] = int(live.get("todayDistanceM") or 0)
        total["s"] = int(round(float(live.get("todayMinutes") or 0) * 60))
        if "todaySteps" in live:
            total["steps"] = int(live["todaySteps"] or 0)
        if "todayKcal" in live:
            total["kcal"] = round(float(live["todayKcal"] or 0), 1)
        if live.get("beltRunning"):
            total["kmh"] = live.get("speedKmh")
    return total


@mcp.tool()
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


def run() -> None:
    parser = argparse.ArgumentParser(description="Read-only Z1 WalkingPad stats MCP server. Control the pad in the macOS app.")
    parser.parse_args()
    mcp.run()


if __name__ == "__main__":
    run()
