import asyncio

import pytest
from types import SimpleNamespace

from z1_walkingpad_mcp.config import GovernorConfig
from z1_walkingpad_mcp.governor import Governor


class FakeTreadmill:
    def __init__(self):
        self.connected = False
        self.belt_running = False
        self.min_speed = 1.6
        self.max_speed = 6.4
        self.device_name = "fake-z1"
        self.status = SimpleNamespace(speed_kmh=0.0, distance_m=0.0, elapsed_s=0, steps=0)
        self.calls = []
        self._status_cbs = []
        self._disconnect_cbs = []
        from z1_walkingpad_mcp.stride import StrideLearner
        import tempfile
        self.stride = StrideLearner(state_file=__import__("pathlib").Path(tempfile.mkdtemp()) / "stride.json")

    async def connect(self): self.connected = True
    async def disconnect(self): self.connected = False
    async def start(self): self.calls.append("start"); self.belt_running = True; self.status.speed_kmh = self.min_speed
    async def pause(self): self.calls.append("pause")
    async def stop(self):
        self.calls.append("stop"); self.belt_running = False; self.status.speed_kmh = 0.0
    async def set_speed(self, kmh): self.calls.append(("set_speed", kmh)); self.status.speed_kmh = kmh
    def session_summary(self):
        return {"duration_s": self.status.elapsed_s, "distance_m": self.status.distance_m,
                "steps": self.status.steps}
    def on_status(self, cb): self._status_cbs.append(cb)
    def on_disconnect(self, cb): self._disconnect_cbs.append(cb)
    def tick(self, speed=2.0, dist=10.0, elapsed=30, steps=20):
        self.status = SimpleNamespace(speed_kmh=speed, distance_m=dist, elapsed_s=elapsed, steps=steps)
        for cb in self._status_cbs: cb(self.status)


def make_gov(tmp_path, motion=True, **kw):
    cfg = GovernorConfig(motion_enabled=motion, ramp_interval_s=0.01, stale_telemetry_s=0.05,
                         step_off_timeout_s=0.1, command_timeout_s=1.0, **kw)
    return Governor(FakeTreadmill(), config=cfg, sessions_dir=tmp_path)


def test_motion_blocked_without_flag(tmp_path):
    g = make_gov(tmp_path, motion=False)
    with pytest.raises(RuntimeError, match="motion disabled"):
        asyncio.run(g.start())


def test_start_and_ramp(tmp_path):
    async def run():
        g = make_gov(tmp_path)
        await g.treadmill.connect()
        await g.start()
        for _ in range(5):
            await asyncio.sleep(0.02)
            g.treadmill.tick(dist=g.treadmill.status.distance_m + 2, steps=g.treadmill.status.steps + 3)
        assert g.state.value == "ramping" or g.state.value == "running"
        await g.stop()
        ready = list(tmp_path.glob("session-*.json"))
        assert len(ready) == 1 and "completed" in ready[0].read_text()
    asyncio.run(run())


def test_step_off_fault(tmp_path):
    async def run():
        g = make_gov(tmp_path)
        await g.treadmill.connect()
        await g.start()
        g.treadmill.tick()  # arm progress
        for _ in range(10):  # keep telemetry fresh but no distance/step progress
            await asyncio.sleep(0.03)
            g.treadmill.tick(speed=2.0, dist=10.0, steps=20)
        await asyncio.sleep(0.15)
        assert g.fault.value == "step_off"
        assert not g.treadmill.belt_running
        await g.resume()
        await g.stop()
    asyncio.run(run())


def test_stale_telemetry_faults(tmp_path):
    async def run():
        g = make_gov(tmp_path)
        await g.treadmill.connect()
        await g.start()
        await asyncio.sleep(0.15)  # no telemetry ticks at all -> stale
        assert g.fault.value == "stale_telemetry"
        assert not g.treadmill.belt_running
    asyncio.run(run())


def test_ble_lost_latches(tmp_path):
    async def run():
        g = make_gov(tmp_path)
        await g.treadmill.connect()
        await g.start()
        g.treadmill.tick()
        for cb in g.treadmill._disconnect_cbs: cb()
        assert g.fault.value == "ble_lost"
        assert g.state.value == "faulted"
        await g.stop()
    asyncio.run(run())


def test_cap_enforcement(tmp_path):
    async def run():
        g = make_gov(tmp_path)
        target = await g.set_speed(9.9)
        assert target == g.config.max_speed_kmh
    asyncio.run(run())
