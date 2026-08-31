"""Two MCP tools. History reads the macOS app's sessions.json.

    python -m z1_walkingpad_mcp.server

One BLE owner. If the menu-bar app is connected, pad() cannot start the belt.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import time
import uuid
from datetime import date
from pathlib import Path

from mcp.server.mcpserver import MCPServer

from . import strava
from .client import Z1Error, Z1Treadmill
from .governor import Governor
from .health_automation import trigger_health_shortcut
from .health_export import build_health_record
from .highscores import export_agent_data, write_agent_export

mcp = MCPServer("z1-walkingpad")
_pad = Z1Treadmill()
governor = Governor(_pad)

if sys.platform == "darwin":
    SESSIONS_DIR = Path(
        os.environ.get(
            "Z1_SESSIONS_DIR",
            Path.home() / "Library/Application Support/Z1 WalkingPad",
        )
    )
else:
    SESSIONS_DIR = Path(os.environ.get("Z1_SESSIONS_DIR", Path.home() / ".z1-walkingpad"))

GOVERNOR_SESSIONS_DIR = governor.sessions_dir
HEALTH_ROUTE = os.environ.get("Z1_HEALTH_ROUTE", "shortcut").strip().lower()
HEALTH_QUEUE_DIR = Path(
    os.environ.get(
        "Z1_HEALTH_QUEUE_DIR",
        Path.home()
        / "Library/Mobile Documents/iCloud~is~workflow~my~workflows/Documents"
        / "z1-walkingpad/health-queue"
        if sys.platform == "darwin"
        else SESSIONS_DIR / "health-queue",
    )
)


def _snap() -> dict:
    s = _pad.status
    summary = _pad.session_summary() or {}
    return {
        "dev": _pad.device_name,
        "kmh": s.speed_kmh,
        "on": bool(s.speed_kmh and s.speed_kmh > 0),
        "m": summary.get("distance_m"),
        "s": summary.get("duration_s") or summary.get("active_duration_s"),
        "steps": summary.get("steps"),
        "kcal": summary.get("calories_kcal") or summary.get("calories"),
    }


async def _end() -> dict:
    has = governor.session_id is not None or _pad.session_clock.started_at is not None
    if not has:
        return {"ok": False, "err": "no session"}
    summary = await governor.stop() if governor.session_id is not None else await _pad.stop()
    compact = {
        "ok": True,
        "m": summary.get("distance_m"),
        "s": summary.get("duration_s") or summary.get("active_duration_s"),
        "steps": summary.get("steps"),
        "kcal": summary.get("calories_kcal") or summary.get("calories"),
    }
    ended_at = time.time()
    session_id = uuid.uuid4().hex
    try:
        SESSIONS_DIR.mkdir(parents=True, exist_ok=True)
        with (SESSIONS_DIR / "sessions.jsonl").open("a") as f:
            f.write(json.dumps({"session_id": session_id, "ended_at": ended_at, **summary}) + "\n")
    except OSError:
        pass
    if HEALTH_ROUTE == "strava" and strava.configured():
        try:
            compact["strava"] = strava.upload_walk(summary, int(ended_at))
        except strava.StravaError as e:
            compact["strava_err"] = str(e)
        return compact
    health_record = build_health_record(summary, ended_at, session_id)
    if health_record is None:
        return compact
    try:
        HEALTH_QUEUE_DIR.mkdir(parents=True, exist_ok=True)
        fd, tmp_name = tempfile.mkstemp(dir=HEALTH_QUEUE_DIR, suffix=".tmp")
        try:
            with os.fdopen(fd, "w") as f:
                json.dump(health_record, f)
            os.replace(tmp_name, HEALTH_QUEUE_DIR / f"health-{session_id}.json")
        except BaseException:
            try:
                os.unlink(tmp_name)
            except OSError:
                pass
            raise
        trigger_health_shortcut()
    except OSError:
        pass
    try:
        write_agent_export(GOVERNOR_SESSIONS_DIR)
    except OSError:
        pass
    return compact


@mcp.tool()
async def pad(op: str, kmh: float | None = None) -> dict:
    """Live belt. op: status|start|stop|pause|resume|speed. kmh for start/speed.
    One BLE client — disconnect the menu-bar app first."""
    op = op.strip().lower()
    if op == "status":
        if not _pad.connected:
            try:
                await governor.connect()
            except Exception as e:
                return {"ok": False, "err": str(e)}
        return {"ok": True, **_snap()}
    if op == "start":
        await governor.connect()
        await governor.start()
        if kmh is not None:
            target = await governor.set_speed(kmh)
        else:
            target = governor.config.default_speed_kmh
        return {"ok": True, "kmh": target}
    if op == "stop":
        return await _end()
    if op == "pause":
        await governor.pause()
        return {"ok": True, "paused": True}
    if op == "resume":
        result = await governor.resume()
        return {"ok": True, "on": bool(result)}
    if op == "speed":
        if kmh is None:
            return {"ok": False, "err": "kmh required"}
        if not _pad.connected:
            await governor.connect()
        await _pad.set_speed(kmh)
        return {"ok": True, "kmh": kmh}
    return {"ok": False, "err": f"unknown op {op}"}


@mcp.tool()
async def walks(op: str = "summary") -> dict:
    """App history (sessions.json). op: summary|today|recent."""
    op = op.strip().lower()
    data = export_agent_data(SESSIONS_DIR)
    if op == "recent":
        return {"ok": True, "recent": data.get("recent", [])}
    if op == "today":
        today = date.today().isoformat()
        rows = [r for r in data.get("recent", []) if str(r.get("start") or "").startswith(today)]
        return {
            "ok": True,
            "n": len(rows),
            "m": sum(int(r.get("m") or 0) for r in rows),
            "s": sum(int(r.get("s") or 0) for r in rows),
            "steps": sum(int(r.get("steps") or 0) for r in rows),
            "kcal": round(sum(float(r.get("kcal") or 0) for r in rows), 1),
            "walks": rows,
        }
    return {"ok": True, **data}


def run() -> None:
    try:
        mcp.run()
    except Z1Error as e:
        raise SystemExit(f"z1-walkingpad-mcp: {e}") from e


if __name__ == "__main__":
    run()
