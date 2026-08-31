"""Read-only. python -m z1_walkingpad_mcp.server"""

from __future__ import annotations

import json
import os
import sys
from datetime import date, datetime, timezone
from pathlib import Path

from mcp.server.mcpserver import MCPServer

mcp = MCPServer("z1")

def _root() -> Path:
    paths = []
    env = os.environ.get("Z1_SESSIONS_DIR")
    if env:
        paths.append(Path(env))
    if sys.platform == "darwin":
        paths.append(Path.home() / "Library/Application Support/Z1 WalkingPad")
    paths.append(Path.home() / ".z1-walkingpad")
    for p in paths:
        if (p / "sessions.json").is_file() or (p / "live.json").is_file():
            return p
    return paths[0]


ROOT = _root()


def _j(name: str) -> dict | list | None:
    try:
        return json.loads((ROOT / name).read_text())
    except (OSError, json.JSONDecodeError, TypeError):
        return None


def _sessions() -> list[dict]:
    raw = _j("sessions.json")
    return raw if isinstance(raw, list) else []


def _row(s: dict) -> dict:
    return {
        "d": str(s.get("startedAt") or "")[:10],
        "m": int(s.get("distanceM") or 0),
        "s": int(s.get("activeDurationS") or 0),
        "steps": int(s.get("steps") or 0),
        "kcal": round(float(s.get("caloriesKcal") or 0), 1),
    }


def _live() -> dict | None:
    data = _j("live.json")
    if not isinstance(data, dict):
        return None
    t = data.get("t")
    if isinstance(t, (int, float)) and datetime.now(timezone.utc).timestamp() - t > 90:
        return None
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
        "m": sum(r["m"] for r in rows),
        "s": sum(r["s"] for r in rows),
        "steps": sum(r["steps"] for r in rows),
        "kcal": round(sum(r["kcal"] for r in rows), 1),
    }


def _today() -> dict:
    day = date.today().isoformat()
    rows = [_row(s) for s in _sessions() if str(s.get("startedAt") or "").startswith(day)]
    tot = _sum(rows)
    tot["d"] = day
    live = _live()
    if live:
        if live["m"] >= tot["m"]:
            tot.update({k: live[k] for k in ("m", "s", "steps", "kcal")})
        else:
            tot["m"] += live["m"]
            tot["s"] += live["s"]
            tot["steps"] += live["steps"]
            tot["kcal"] = round(tot["kcal"] + live["kcal"], 1)
        if live.get("on"):
            tot["kmh"] = live["kmh"]
    return tot


@mcp.tool()
async def z1(q: str = "today") -> dict:
    """Walk stats. q=today (default)|live|all|list. Read-only."""
    q = (q or "today").strip().lower()
    if q in ("", "today", "t"):
        return _today()
    if q in ("live", "l"):
        return _live() or {}
    rows = [_row(s) for s in _sessions()]
    if q in ("list", "recent", "r"):
        return {"list": rows[-5:]}
    tot = _sum(rows)
    tot["n"] = len(rows)
    return tot


def run() -> None:
    mcp.run()


if __name__ == "__main__":
    run()
