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
import json
import time
from collections.abc import Callable
from pathlib import Path

from bleak import BleakClient, BleakScanner
from bleak.backends.device import BLEDevice

from . import constants as c
from . import protocol as p
from .metrics import CalorieTracker
from .models import StepSource
from .session_clock import SessionClock
from .stepper import StepEstimator
from .stride import StrideLearner

# Calorie integration is client-side, so it survives reconnects via this file:
# pad counters (elapsed/distance/steps) persist on the pad; we persist the kcal
# total keyed against them and restore on the next connection.
CALORIE_STATE_FILE = Path.home() / ".z1-walkingpad" / "calorie-state.json"

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


class ControlRefused(Z1Error):
    """Control point answered with a non-success result code."""

    def __init__(self, op: int, result: int) -> None:
        self.op = op
        self.result = result
        super().__init__(f"control point refused op {op:#04x}: {CP_RESULT.get(result, f'code {result}')}")


# vendor control tunnel opcodes mirror FTMS (see docs/protocol.md)
TUNNEL_FRAME = lambda op, params: p.build_frame(0x77, 0x01, bytes([op]) + params)


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
        # derived live from telemetry — the pad may be started/stopped by
        # the physical remote at any time, so commands never own this
        self.belt_running = False
        # The pad is the master of counters: time/distance/steps are shown
        # exactly as the pad reports them (it resets them on Stop and on its
        # own schedule). Calories are computed client-side but follow the
        # same lifecycle — the tracker resets whenever the pad's counters do.
        self.calories = CalorieTracker()
        self._last_target_speed: float | None = None
        self._calorie_state_restored = False
        self.stride = StrideLearner()
        self.stepper = StepEstimator(self.stride)
        self._corrected_steps = 0.0
        self._step_baselined = False
        self.last_steps_delta = 0.0
        self.last_step_source = StepSource.UNKNOWN
        self.session_clock = SessionClock()
        self._last_telemetry_monotonic: float | None = None
        self._disconnect_callbacks: list[Callable[[], None]] = []

    @property
    def steps_display(self) -> int | None:
        """Step count to show: distance-derived estimate once the stride
        curve is calibrated, raw pad count before that."""
        if self._step_baselined:
            return round(self._corrected_steps)
        return self.status.steps

    # -- callbacks ------------------------------------------------------

    def on_status(self, cb: Callable[[p.TreadmillData], None]) -> None:
        self._status_callbacks.append(cb)

    def on_disconnect(self, cb: Callable[[], None]) -> None:
        self._disconnect_callbacks.append(cb)

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

        # silence the buzzer (prop 8 bit 1) on every connect — best-effort
        try:
            cur = self.properties.get(8, 0)
            if cur & 0x02:
                await self._vendor_roundtrip(
                    p.property_write_frame(8, cur & ~0x02),
                    lambda f: f[0] == c.VOP_PROPERTY and f[1] == 0x81,
                )
                self.properties[8] = cur & ~0x02
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
        self.session_clock.pause()
        self.unlocked = False
        self._has_control = False
        self.belt_running = False
        self._calorie_state_restored = False
        for callback in list(self._disconnect_callbacks):
            try:
                callback()
            except Exception:
                pass

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
                if result == 5:
                    self._has_control = False  # re-request control next time
                raise ControlRefused(resp[1], result)
        return resp

    async def _vendor_control(self, op: int, params: bytes = b"") -> None:
        """0x77 vendor control tunnel — fallback when the control point
        refuses (the pad sometimes transiently answers result 4 after a
        session; the tunnel is the documented alternate path)."""
        resp = await self._vendor_roundtrip(
            TUNNEL_FRAME(op, params),
            lambda f: f[0] == 0x77 and f[1] == 0x81 and len(f[2]) >= 2 and f[2][0] == op,
        )
        if resp[2][1] not in (0, 0x81):
            raise Z1Error(f"vendor tunnel refused op {op:#04x}: status {resp[2][1]:#04x}")

    async def _control_command(self, cp_bytes: bytes, tunnel_op: int, tunnel_params: bytes = b"") -> None:
        """Send a control command, retrying once after a transient refusal
        (result 4), then falling back to the 0x77 vendor tunnel."""
        try:
            await self._cp_command(cp_bytes)
        except ControlRefused as e:
            if e.result != 4:
                raise
            await asyncio.sleep(3)
            try:
                await self._cp_command(cp_bytes)
            except ControlRefused as e2:
                if e2.result != 4:
                    raise
                await self._vendor_control(tunnel_op, tunnel_params)

    async def _ensure_control(self) -> None:
        if not self._has_control:
            await self._cp_command(bytes([c.OP_REQUEST_CONTROL]))
            self._has_control = True

    # -- public control API ----------------------------------------------

    async def start(self) -> None:
        self._require_unlocked()
        await self._ensure_control()
        # the pad refuses START (result 4) when the belt is already moving —
        # e.g. started by the physical remote. Nothing to do in that case.
        if not self.belt_running:
            await self._control_command(bytes([c.OP_START_OR_RESUME]), 0x07)
        self.session_clock.start()
        self._last_target_speed = None  # belt restarts at minimum speed

    async def stop(self) -> dict:
        self._require_unlocked()
        await self._ensure_control()
        self.session_clock.pause()
        # summary first: the pad resets its counters when Stop lands
        summary = self.session_summary()
        try:
            await self._control_command(bytes([c.OP_STOP_OR_PAUSE, c.STOP_PARAM_STOP]), 0x08, b"\x01")
        except BaseException:
            self.session_clock.start()
            raise
        self.session_clock.reset()
        return summary

    async def pause(self) -> None:
        self._require_unlocked()
        await self._ensure_control()
        await self._control_command(bytes([c.OP_STOP_OR_PAUSE, c.STOP_PARAM_PAUSE]), 0x08, b"\x02")
        self.session_clock.pause()

    async def set_speed(self, kmh: float) -> None:
        self._require_unlocked()
        if not self.min_speed <= kmh <= self.max_speed:
            raise Z1Error(f"speed {kmh} out of range {self.min_speed}-{self.max_speed} km/h")
        await self._ensure_control()
        value = round(kmh * 100).to_bytes(2, "little")
        await self._control_command(bytes([c.OP_SET_TARGET_SPEED]) + value, 0x02, value)
        self._last_target_speed = kmh

    async def speed_up(self, delta_kmh: float = 0.1) -> float:
        """Nudge speed up; returns the new target."""
        return await self._nudge_speed(delta_kmh)

    async def speed_down(self, delta_kmh: float = 0.1) -> float:
        """Nudge speed down; returns the new target."""
        return await self._nudge_speed(-delta_kmh)

    async def _nudge_speed(self, delta: float) -> float:
        # delta already snapped to 0.1 kmh by caller; coalesce rapid taps via last target
        current = self._last_target_speed or self.status.speed_kmh or self.min_speed
        target = round((current + delta) * 10) / 10
        if target == current:
            # tiny delta rounded away — force one pad step
            step = 0.1 if delta >= 0 else -0.1
            target = round((current + step) * 10) / 10
        target = max(self.min_speed, min(self.max_speed, target))
        await self.set_speed(target)
        return target

    def session_summary(self) -> dict:
        """Current session metrics: the pad's own counters plus our kcal."""
        timing = self.session_clock.snapshot()
        active_s = round(timing["active_duration_s"])
        duration_s = active_s or self.status.elapsed_s
        distance_m = self.status.distance_m
        avg_kmh = round(distance_m / duration_s * 3.6, 2) if duration_s and distance_m else None
        return {
            "duration_s": duration_s,
            "active_duration_s": duration_s,
            "started_at": timing["started_at"],
            "distance_m": distance_m,
            "steps": self.steps_display,
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
        telemetry_now = time.monotonic()
        prev = self.status
        parsed = p.parse_treadmill_data(bytes(data))
        # FTMS permits sparse packets.  Keep the last counters instead of
        # turning an omitted field into zero and adding the full session again
        # on the next complete packet.
        for field in ("speed_kmh", "distance_m", "elapsed_s", "steps", "calories"):
            if getattr(parsed, field) is None:
                setattr(parsed, field, getattr(prev, field))
        self.status = parsed

        was_running = self.belt_running
        now_running = bool(self.status.speed_kmh and self.status.speed_kmh > 0)
        if now_running and not was_running:
            if self.session_clock.started_at is None and (self.status.elapsed_s or 0) > 5:
                self.session_clock.seed_running_elapsed(
                    self.status.elapsed_s or 0,
                    monotonic_time=telemetry_now,
                )
            else:
                self.session_clock.start(monotonic_time=telemetry_now)
        elif was_running and not now_running:
            self.session_clock.pause(monotonic_time=telemetry_now)

        if not self._calorie_state_restored:
            self._calorie_state_restored = True
            self._restore_calorie_state()

        first_counters = prev.distance_m is None or prev.steps is None
        if first_counters and not self._step_baselined:
            self._corrected_steps = float(self.status.steps or 0)
            self._step_baselined = True
        # pad counter reset (Stop finalizes the pad session, or the pad's
        # own timer): the pad is the master — our calorie count resets with it
        regressed = any(
            before is not None and after is not None and after < before
            for before, after in (
                (prev.elapsed_s, self.status.elapsed_s),
                (prev.distance_m, self.status.distance_m),
                (prev.steps, self.status.steps),
            )
        )
        if regressed:
            self.calories.reset()
            self._corrected_steps = 0.0
            self._step_baselined = True
            self.last_steps_delta = 0.0
            self.last_step_source = StepSource.UNKNOWN
        else:
            steps_delta, source = self.stepper.feed(
                prev.distance_m,
                prev.steps,
                self.status.distance_m,
                self.status.steps,
                self.status.speed_kmh,
                prev.elapsed_s,
                self.status.elapsed_s,
                prev.speed_kmh,
            )
            if not first_counters:
                self._corrected_steps += steps_delta
            self.last_steps_delta = 0.0 if first_counters else steps_delta
            self.last_step_source = source
        # belt state is derived from the pad (the master): it may have been
        # started/stopped by the physical remote between our commands
        self.belt_running = now_running
        # credit calorie burn for the interval just elapsed, while moving
        telemetry_gap = (
            telemetry_now - self._last_telemetry_monotonic
            if self._last_telemetry_monotonic is not None
            else 0.0
        )
        # A long gap is a disconnect or pause, not many minutes of walking at
        # the last known speed. Normal FTMS frames arrive about once a second.
        if 0 < telemetry_gap <= 5 and prev.speed_kmh and prev.speed_kmh > 0 and now_running:
            self.calories.add_sample(prev.speed_kmh, telemetry_gap)
        self._last_telemetry_monotonic = telemetry_now
        self._persist_calorie_state()
        self._emit_status()

    # -- calorie state persistence ----------------------------------------

    _last_persist_monotonic: float | None = None
    def _persist_calorie_state(self, force: bool = False) -> None:
        # throttle to every 5s — not every 1Hz tick (perf)
        import time as _t
        now = _t.monotonic()
        if not force and self._last_persist_monotonic is not None and now - self._last_persist_monotonic < 5:
            return
        self._last_persist_monotonic = now
        try:
            CALORIE_STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
            CALORIE_STATE_FILE.write_text(
                json.dumps(
                    {
                        "total_kcal": self.calories.total_kcal,
                        "corrected_steps": self._corrected_steps,
                        "raw_steps": self.status.steps,
                        "elapsed_s": self.status.elapsed_s,
                        "distance_m": self.status.distance_m,
                    }
                )
            )
        except OSError:
            pass

    def _restore_calorie_state(self) -> None:
        try:
            state = json.loads(CALORIE_STATE_FILE.read_text())
        except (OSError, json.JSONDecodeError):
            return
        cur_elapsed = self.status.elapsed_s
        if cur_elapsed is None:
            return
        saved_elapsed = state.get("elapsed_s") or 0
        if cur_elapsed < saved_elapsed:
            return  # pad counters went backwards (power cycle) — start fresh
        self.calories.total_kcal = float(state.get("total_kcal") or 0)
        self._corrected_steps = float(state.get("corrected_steps") or 0)
        self._step_baselined = True
        # credit the gap while we were disconnected, if the belt kept moving
        gap_s = cur_elapsed - saved_elapsed
        gap_d = (self.status.distance_m or 0) - (state.get("distance_m") or 0)
        saved_raw_steps = state.get("raw_steps")
        gap_raw_steps = (
            max(0, (self.status.steps or 0) - int(saved_raw_steps))
            if saved_raw_steps is not None
            else None
        )
        if gap_s > 0 and gap_d > 0:
            avg_kmh = gap_d / gap_s * 3.6
            self.calories.add_sample(avg_kmh, gap_s)
            stride = self.stride.stride_for(avg_kmh)
            if stride:
                self._corrected_steps += gap_d / stride
            elif gap_raw_steps is not None:
                self._corrected_steps += gap_raw_steps
            else:
                # Compatibility with old state files that did not save the
                # raw counter.  A raw baseline is safer than displaying zero.
                self._corrected_steps = float(self.status.steps or 0)

    def _on_machine_status(self, _char, data: bytearray) -> None:
        # belt-state events from the pad itself: works even when no
        # treadmill-data frames flow (e.g. belt fully stopped)
        if not data:
            return
        op = data[0]
        if op == 4:  # started
            self.session_clock.start()
            self.belt_running = True
            self._emit_status()
        elif op in (1, 2):  # safety-key stop / user stop or pause
            self.session_clock.pause()
            self.belt_running = False
            self._emit_status()

    # -- helpers ------------------------------------------------------------

    def _require_unlocked(self) -> None:
        if not self.connected:
            raise Z1Error("not connected/unlocked — call connect() first")

    async def _pace(self, attr: str, interval: float) -> None:
        elapsed = time.monotonic() - getattr(self, attr)
        if elapsed < interval:
            await asyncio.sleep(interval - elapsed)
        setattr(self, attr, time.monotonic())
