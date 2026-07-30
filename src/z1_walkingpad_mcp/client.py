"""Async BLE client for the KingSmith WalkingPad Z1.

Protocol recap (discovered 2026-07-30, see docs/discovery.md):
the pad ignores every FTMS control point command and suppresses all
notifications until the supplement-channel unlock frame lands. Order:

1. subscribe supplement notify characteristic
2. send unlock frame (write WITHOUT response)
3. await 71 80 -> send SYS_INFO -> SETTING_GET
4. FTMS works from here on: request control -> start/stop/set speed
"""

from __future__ import annotations

import asyncio
import time
from collections.abc import Callable

from bleak import BleakClient, BleakScanner
from bleak.backends.device import BLEDevice

from . import constants as c
from . import protocol as p
from .metrics import CalorieTracker

CP_RESULT = {1: "success", 2: "op not supported", 3: "invalid parameter", 4: "failed", 5: "control not permitted"}

# Property IDs in the SETTING_GET dump
PROP_UNITS = 1
PROP_AUTO_STOP = 2
PROP_MOTOR_VERSION = 4
PROP_LAST_ERROR = 5
PROP_CHILD_LOCK = 6
PROP_SWITCHES = 8
PROP_MODE = 10


class Z1Error(RuntimeError):
    pass


class Z1Treadmill:
    def __init__(self, device_name: str | None = None) -> None:
        self.device_name = device_name
        self.client: BleakClient | None = None
        self.status = p.TreadmillData()
        self.properties: dict[int, int] = {}
        self.min_speed = 1.6
        self.max_speed = 6.4
        self.unlocked = False
        self._has_control = False
        self._unlocked_event = asyncio.Event()
        self._vendor_waiters: list[tuple[Callable[[tuple[int, int, bytes]], bool], asyncio.Future]] = []
        self._cp_waiters: list[asyncio.Future] = []
        self._last_vendor_write = 0.0
        self._last_cp_write = 0.0
        self._status_callbacks: list[Callable[[p.TreadmillData], None]] = []
        self.calories = CalorieTracker()
        self._session_baseline: p.TreadmillData | None = None
        self._last_target_speed: float | None = None

    # -- callbacks ------------------------------------------------------

    def on_status(self, cb: Callable[[p.TreadmillData], None]) -> None:
        self._status_callbacks.append(cb)

    def _emit_status(self) -> None:
        for cb in self._status_callbacks:
            cb(self.status)

    # -- connection -----------------------------------------------------

    async def connect(self, timeout: float = 20.0) -> None:
        if self.client and self.client.is_connected:
            return
        if self.device_name:
            device = await BleakScanner.find_device_by_name(self.device_name, timeout=timeout)
        else:
            device = await BleakScanner.find_device_by_filter(
                lambda d, _ad: (d.name or "").startswith(c.DEVICE_NAME_PREFIX), timeout=timeout
            )
        if device is None:
            raise Z1Error("Z1 treadmill not found (is it on and not connected to another app?)")
        await self._connect_device(device)

    async def _connect_device(self, device: BLEDevice) -> None:
        self.device_name = device.name
        self.client = BleakClient(device, disconnected_callback=lambda _c: self._on_disconnect())
        await self.client.connect()

        # 1. supplement notify FIRST — before any vendor write
        await self.client.start_notify(c.CHAR_SUPPLEMENT_NOTIFY, self._on_vendor_notify)
        # telemetry + machine status (informational; may stay silent pre-unlock)
        for char, handler in (
            (c.CHAR_TREADMILL_DATA, self._on_treadmill_data),
            (c.CHAR_FITNESS_MACHINE_STATUS, self._on_machine_status),
        ):
            try:
                await self.client.start_notify(char, handler)
            except Exception:
                pass

        # 2. unlock — write without response, fire-and-forget
        self._unlocked_event.clear()
        await self.client.write_gatt_char(c.CHAR_SUPPLEMENT_WRITE, p.unlock_frame(device.name), response=False)
        try:
            await asyncio.wait_for(self._unlocked_event.wait(), c.UNLOCK_TIMEOUT_S)
        except asyncio.TimeoutError as e:
            raise Z1Error("unlock timed out — pad did not answer the supplement handshake") from e
        self.unlocked = True

        # 3. extension init (best-effort: pad still works if these time out)
        try:
            await self._vendor_roundtrip(
                p.sysinfo_frame(int(time.time())),
                lambda f: f[0] == c.VOP_UNLOCK and f[1] == 0x81,
            )
        except Z1Error:
            pass
        try:
            resp = await self._vendor_roundtrip(
                p.setting_get_frame(0),
                lambda f: f[0] == c.VOP_PROPERTY and f[1] == 0x80,
            )
            self.properties = p.parse_property_records(resp[2])
        except Z1Error:
            pass

        # FTMS statics + control point indications
        try:
            rng = await self.client.read_gatt_char(c.CHAR_SUPPORTED_SPEED_RANGE)
            self.min_speed = int.from_bytes(rng[0:2], "little") / 100
            self.max_speed = int.from_bytes(rng[2:4], "little") / 100
        except Exception:
            pass
        await self.client.start_notify(c.CHAR_CONTROL_POINT, self._on_cp_indicate)

    def _on_disconnect(self) -> None:
        self.unlocked = False
        self._has_control = False

    async def disconnect(self) -> None:
        if self.client and self.client.is_connected:
            try:
                if self._has_control:
                    await self.stop()
            except Exception:
                pass
            await self.client.disconnect()

    @property
    def connected(self) -> bool:
        return bool(self.client and self.client.is_connected and self.unlocked)

    # -- vendor channel -------------------------------------------------

    def _on_vendor_notify(self, _char, data: bytearray) -> None:
        raw = bytes(data)
        if p.is_unlock_ok(raw):
            self._unlocked_event.set()
        parsed = p.parse_frame(raw)
        if parsed is None:
            return
        for pred, fut in list(self._vendor_waiters):
            if not fut.done() and pred(parsed):
                fut.set_result(parsed)

    async def _vendor_roundtrip(
        self, frame: bytes, pred: Callable[[tuple[int, int, bytes]], bool], timeout: float = c.VENDOR_RESPONSE_TIMEOUT_S
    ) -> tuple[int, int, bytes]:
        assert self.client is not None
        loop = asyncio.get_event_loop()
        fut: asyncio.Future = loop.create_future()
        self._vendor_waiters.append((pred, fut))
        try:
            await self._pace("_last_vendor_write", c.VENDOR_MIN_INTERVAL_S)
            await self.client.write_gatt_char(c.CHAR_SUPPLEMENT_WRITE, frame, response=False)
            return await asyncio.wait_for(fut, timeout)
        except asyncio.TimeoutError as e:
            raise Z1Error("vendor frame response timed out") from e
        finally:
            self._vendor_waiters = [(pr, fu) for pr, fu in self._vendor_waiters if fu is not fut]

    # -- FTMS control point ----------------------------------------------

    def _on_cp_indicate(self, _char, data: bytearray) -> None:
        for fut in list(self._cp_waiters):
            if not fut.done():
                fut.set_result(bytes(data))

    async def _cp_command(self, cmd: bytes) -> bytes:
        assert self.client is not None
        loop = asyncio.get_event_loop()
        fut: asyncio.Future = loop.create_future()
        self._cp_waiters.append(fut)
        try:
            await self._pace("_last_cp_write", c.CONTROL_MIN_INTERVAL_S)
            await self.client.write_gatt_char(c.CHAR_CONTROL_POINT, cmd, response=True)
            resp = await asyncio.wait_for(fut, c.VENDOR_RESPONSE_TIMEOUT_S)
        except asyncio.TimeoutError as e:
            raise Z1Error("control point indication timed out") from e
        finally:
            self._cp_waiters = [f for f in self._cp_waiters if f is not fut]
        # indication: 80 <request-op> <result> [params...]
        if len(resp) >= 3 and resp[0] == 0x80:
            result = resp[2]
            if result != 1:
                raise Z1Error(f"control point refused op {resp[1]:#04x}: {CP_RESULT.get(result, f'code {result}')}")
        return resp

    async def _ensure_control(self) -> None:
        if not self._has_control:
            await self._cp_command(bytes([c.OP_REQUEST_CONTROL]))
            self._has_control = True

    # -- public control API ----------------------------------------------

    async def start(self) -> None:
        self._require_unlocked()
        await self._ensure_control()
        await self._cp_command(bytes([c.OP_START_OR_RESUME]))
        # pad counters are cumulative across connections — snapshot a baseline
        self._session_baseline = p.TreadmillData(
            distance_m=self.status.distance_m, elapsed_s=self.status.elapsed_s, steps=self.status.steps
        )
        self.calories.reset()
        self._last_target_speed = None  # belt restarts at minimum speed

    async def stop(self) -> dict:
        self._require_unlocked()
        await self._ensure_control()
        await self._cp_command(bytes([c.OP_STOP_OR_PAUSE, c.STOP_PARAM_STOP]))
        return self.session_summary()

    async def pause(self) -> None:
        self._require_unlocked()
        await self._ensure_control()
        await self._cp_command(bytes([c.OP_STOP_OR_PAUSE, c.STOP_PARAM_PAUSE]))

    async def set_speed(self, kmh: float) -> None:
        self._require_unlocked()
        if not self.min_speed <= kmh <= self.max_speed:
            raise Z1Error(f"speed {kmh} out of range {self.min_speed}-{self.max_speed} km/h")
        await self._ensure_control()
        value = round(kmh * 100).to_bytes(2, "little")
        await self._cp_command(bytes([c.OP_SET_TARGET_SPEED]) + value)
        self._last_target_speed = kmh

    async def speed_up(self, delta_kmh: float = 0.1) -> float:
        """Nudge speed up; returns the new target."""
        return await self._nudge_speed(delta_kmh)

    async def speed_down(self, delta_kmh: float = 0.1) -> float:
        """Nudge speed down; returns the new target."""
        return await self._nudge_speed(-delta_kmh)

    async def _nudge_speed(self, delta: float) -> float:
        # prefer the last commanded target: telemetry lags ~1s, so rapid
        # successive nudges would otherwise re-read the stale speed
        current = self._last_target_speed or self.status.speed_kmh or self.min_speed
        target = round((current + delta) * 10) / 10  # pad steps are 0.1 km/h
        target = max(self.min_speed, min(self.max_speed, target))
        await self.set_speed(target)
        return target

    def session_summary(self) -> dict:
        """Metrics since the last start(): duration, distance, steps, calories."""
        base = self._session_baseline or p.TreadmillData()

        def delta(cur: int | None, ref: int | None) -> int | None:
            if cur is None:
                return None
            return cur - (ref or 0)

        duration_s = delta(self.status.elapsed_s, base.elapsed_s)
        distance_m = delta(self.status.distance_m, base.distance_m)
        avg_kmh = round(distance_m / duration_s * 3.6, 2) if duration_s and distance_m else None
        return {
            "duration_s": duration_s,
            "distance_m": distance_m,
            "steps": delta(self.status.steps, base.steps),
            "avg_speed_kmh": avg_kmh,
            "calories_kcal": round(self.calories.total_kcal, 1),
            "weight_kg_used": self.calories.weight_kg,
        }

    async def read_properties(self) -> dict[int, int]:
        self._require_unlocked()
        resp = await self._vendor_roundtrip(
            p.setting_get_frame(0), lambda f: f[0] == c.VOP_PROPERTY and f[1] == 0x80
        )
        self.properties = p.parse_property_records(resp[2])
        return self.properties

    # -- telemetry --------------------------------------------------------

    def _on_treadmill_data(self, _char, data: bytearray) -> None:
        prev = self.status
        self.status = p.parse_treadmill_data(bytes(data))
        # credit calorie burn for the interval just elapsed, while moving
        if (
            prev.elapsed_s is not None
            and self.status.elapsed_s is not None
            and prev.speed_kmh
            and prev.speed_kmh > 0
        ):
            self.calories.add_sample(prev.speed_kmh, self.status.elapsed_s - prev.elapsed_s)
        self._emit_status()

    def _on_machine_status(self, _char, data: bytearray) -> None:
        pass  # op codes logged by callers that care; belt state comes via 0x2ACD

    # -- helpers ------------------------------------------------------------

    def _require_unlocked(self) -> None:
        if not self.connected:
            raise Z1Error("not connected/unlocked — call connect() first")

    async def _pace(self, attr: str, interval: float) -> None:
        elapsed = time.monotonic() - getattr(self, attr)
        if elapsed < interval:
            await asyncio.sleep(interval - elapsed)
        setattr(self, attr, time.monotonic())
