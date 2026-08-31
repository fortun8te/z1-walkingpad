"""Read-only MCP. No BLE, no start/stop.

    python -m z1_walkingpad_mcp.server
"""

from __future__ import annotations

import json
import os
import sys
from datetime import date, datetime, timezone
from pathlib import Path

from mcp.server.mcpserver import MCPServer

from .highscores import export_agent_data

mcp = MCPServer("z1-walkingpad")

if sys.platform == "darwin":
    ROOT = Path(
        os.environ.get(
            "Z1_SESSIONS_DIR",
            Path.home() / "Library/Application Support/Z1 WalkingPad",
        )
    )
else:
    ROOT = Path(os.environ.get("Z1_SESSIONS_DIR", Path.home() / ".z1-walkingpad"))


def _live() -> dict | None:
    path = ROOT / "live.json"
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return None
    t = data.get("t")
    if isinstance(t, (int, float)) and (datetime.now(timezone.utc).timestamp() - t) > 90:
        data["stale"] = True
    return data


@mcp.tool()
async def walks(op: str = "summary") -> dict:
    """Read walks. op=summary|today|live|recent. No belt control."""
    op = (op or "summary").strip().lower()
    live = _live()
    if op == "live":
        return {"ok": True, "live": live}
    data = export_agent_data(ROOT)
    if op == "recent":
        return {"ok": True, "recent": data.get("recent", [])}
    if op == "today":
        today = date.today().isoformat()
        rows = [r for r in data.get("recent", []) if str(r.get("start") or "").startswith(today)]
        out = {
            "ok": True,
            "n": len(rows),
            "m": sum(int(r.get("m") or 0) for r in rows),
            "s": sum(int(r.get("s") or 0) for r in rows),
            "steps": sum(int(r.get("steps") or 0) for r in rows),
            "kcal": round(sum(float(r.get("kcal") or 0) for r in rows), 1),
        }
        if live and not live.get("stale") and live.get("on"):
            out["live"] = live
        return out
    out = {"ok": True, "n": data.get("n"), "totals": data.get("totals")}
    if live and not live.get("stale"):
        out["live"] = live
    return out


def run() -> None:
    mcp.run()


if __name__ == "__main__":
    run()
