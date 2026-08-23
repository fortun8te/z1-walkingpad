from __future__ import annotations

import asyncio
import json
from pathlib import Path

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from z1_walkingpad_mcp.client import Z1Treadmill
from z1_walkingpad_mcp.config import GovernorConfig
from z1_walkingpad_mcp.governor import Governor
from z1_walkingpad_mcp.session_recorder import recover_incomplete

import os

app = FastAPI(title="Z1 Dashboard")

treadmill = Z1Treadmill()
governor = Governor(treadmill)
_connected = False
SESSIONS_DIR = governor.sessions_dir


@app.on_event("startup")
async def startup():
    global _connected
    try:
        await asyncio.wait_for(governor.connect(), timeout=3)
        _connected = True
    except asyncio.TimeoutError:
        print("BLE scan timed out (expected before Warp permission) — lazy connect enabled.")
    except Exception as e:
        print(f"BLE connect failed: {e}")


@app.get("/api/status")
async def status():
    if not globals()["_connected"]:
        try:
            await asyncio.wait_for(governor.connect(), timeout=5)
            globals()["_connected"] = True
        except Exception:
            pass
    return governor.status_dict()


@app.post("/api/speed/{kmh}")
async def set_speed_route(kmh: float):
    target = await governor.set_speed(kmh)
    return {"ok": True, "target_kmh": target}


@app.post("/api/start")
async def start():
    await governor.connect()
    result = await governor.start()
    return {"ok": True, **result}


@app.post("/api/pause")
async def pause():
    await governor.pause()
    return {"ok": True}


@app.post("/api/resume")
async def resume():
    await governor.resume()
    return {"ok": True}


@app.post("/api/stop")
async def stop():
    summary = await governor.stop()
    return {"ok": True, "summary": summary}


@app.post("/api/speed")
async def set_speed(kmh: float):
    target = await governor.set_speed(kmh)
    return {"ok": True, "target_kmh": target}


@app.websocket("/ws")
async def ws(ws: WebSocket):
    await ws.accept()
    last_state = None
    try:
        while True:
            current = governor.status_dict()
            if current != last_state:
                await ws.send_json(current)
                last_state = current.copy()
            await asyncio.sleep(0.5)
    except WebSocketDisconnect:
        pass


@app.get("/api/sessions")
async def list_sessions():
    recover_incomplete(SESSIONS_DIR)
    files = sorted(SESSIONS_DIR.glob("session-*.json"), reverse=True)[:50]
    out = []
    for f in files:
        try:
            data = json.loads(f.read_text())
            data["file"] = f.name
            out.append(data)
        except (OSError, json.JSONDecodeError):
            continue
    return out


static_dir = Path(__file__).parent.parent / "frontend"
if static_dir.exists():
    app.mount("/", StaticFiles(directory=static_dir, html=True), name="static")
