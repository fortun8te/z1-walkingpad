from __future__ import annotations

import asyncio
import json
from dataclasses import replace
from pathlib import Path

from .client import Z1Treadmill
from .config import GovernorConfig
from .models import FaultCode, GovernorState, StepSource, GovernorStatus
from .ramping import SpeedRamp
from .session_recorder import SessionRecorder
from .stepper import StepEstimator


class Governor:
    def __init__(
        self,
        treadmill: Z1Treadmill | None = None,
        config: GovernorConfig | None = None,
        sessions_dir: Path | None = None,
    ) -> None:
        self.treadmill = treadmill if treadmill is not None else Z1Treadmill()
        self.config = config if config is not None else GovernorConfig.from_env()
        self.config.validate()
        self.sessions_dir = sessions_dir or Path.home() / ".z1-walkingpad" / "sessions"
        self.ramp = SpeedRamp(self.config)
        self.stepper = StepEstimator(self.treadmill.stride)
        self.recorder = SessionRecorder(self.sessions_dir)
        self.state = GovernorState.DISCONNECTED
        self.fault = FaultCode.NONE
        self.target_speed_kmh: float | None = None
        self.session_id: str | None = None
        self.message = ""
        self._supervisor_task: asyncio.Task | None = None
        self._last_telemetry_ts = 0.0
        self._last_progress_ts = 0.0
        self._step_off_armed = False
        self._prev_distance_m: float | None = None
        self._prev_steps: int | None = None
        self.treadmill.on_status(self._on_status_tick)
        self.treadmill.on_disconnect(self._on_ble_lost)

    def _require_motion(self) -> None:
        if not self.config.motion_enabled:
            raise RuntimeError("motion disabled (set Z1_ENABLE_MOTION=1)")

    async def connect(self) -> None:
        await asyncio.wait_for(self.treadmill.connect(), self.config.command_timeout_s * 4)
        self.state = GovernorState.READY
        if self.recorder.session_id is None:
            pass  # recorder starts on first motion command

    async def disconnect(self) -> None:
        await self.stop()
        await self.treadmill.disconnect()
        self.state = GovernorState.DISCONNECTED

    async def start(self) -> dict:
        self._require_motion()
        if self.fault is not FaultCode.NONE:
            raise RuntimeError(f"faulted ({self.fault.value}); resume required")
        self.state = GovernorState.STARTING
        if self.session_id is None:
            self.session_id = self.recorder.start({"device": self.treadmill.device_name})
        self.recorder.log("command", {"op": "start"})
        await asyncio.wait_for(self.treadmill.start(), self.config.command_timeout_s)
        self.target_speed_kmh = self.ramp.clamp(self.config.default_speed_kmh)
        self._last_progress_ts = asyncio.get_event_loop().time()
        self.state = GovernorState.RAMPING
        if not self._supervisor_task or self._supervisor_task.done():
            self._supervisor_task = asyncio.get_event_loop().create_task(self._supervise())
        return {"target_speed_kmh": self.target_speed_kmh}

    async def pause(self) -> None:
        self.recorder.log("command", {"op": "pause"})
        await asyncio.wait_for(self.treadmill.pause(), self.config.command_timeout_s)
        self.state = GovernorState.PAUSED

    async def resume(self) -> dict | None:
        if self.fault is not FaultCode.NONE:
            self.fault = FaultCode.NONE
            self.message = "manual resume after fault"
            self.state = GovernorState.READY
            self._supervisor_task = None
            self.recorder.log("resume", {"after_fault": True})
        self._require_motion()
        return await self.start() if not self.treadmill.belt_running else None

    async def set_speed(self, kmh: float) -> float:
        self._require_motion()
        target = self.ramp.clamp(kmh)
        self.recorder.log("command", {"op": "set_speed", "target": target})
        await asyncio.wait_for(self.treadmill.set_speed(target), self.config.command_timeout_s)
        self.target_speed_kmh = target
        return target

    def configure(self, **overrides) -> GovernorConfig:
        self.config = replace(self.config, **overrides)
        self.config.validate()
        self.ramp = SpeedRamp(self.config)
        return self.config

    async def stop(self) -> dict:
        if self.state is GovernorState.STOPPING or self.state is GovernorState.DISCONNECTED:
            return {}
        self.state = GovernorState.STOPPING
        try:
            summary = self.treadmill.session_summary()
        except Exception:
            summary = {}
        try:
            await asyncio.wait_for(self.treadmill.stop(), self.config.command_timeout_s)
        except Exception as exc:
            self.fault = FaultCode.COMMAND_TIMEOUT
            self.message = f"stop failed: {exc}"
            self.state = GovernorState.FAULTED
            self.recorder.log("stop_failed", {"error": str(exc)})
            raise
        if self._supervisor_task and not self._supervisor_task.done():
            self._supervisor_task.cancel()
        outcome = "faulted" if self.fault is not FaultCode.NONE else "completed"
        if self.recorder.session_id is not None:
            self.recorder.log("stop", {"outcome": outcome})
            self.recorder.finalize(outcome=outcome, summary={**summary, "fault": self.fault.value})
            self.recorder.session_id = None
        self.session_id = None
        self._prev_distance_m = None
        self._prev_steps = None
        self._step_off_armed = False
        self.state = GovernorState.READY
        return summary

    def status_dict(self) -> dict:
        s = self.treadmill.status
        status = GovernorStatus(
            state=self.state,
            fault=self.fault,
            target_speed_kmh=self.target_speed_kmh,
            current_speed_kmh=s.speed_kmh,
            distance_m=s.distance_m,
            elapsed_s=s.elapsed_s,
            steps=self.treadmill.steps_display,
            step_source=StepSource.CALIBRATED if self.stepper.calibrated else StepSource.UNKNOWN,
            session_id=self.session_id,
            message=self.message,
        )
        return status.to_dict()

    async def status(self) -> dict:
        return self.status_dict()

    def _on_ble_lost(self) -> None:
        if self.state in {GovernorState.RUNNING, GovernorState.RAMPING, GovernorState.PAUSED}:
            self.fault = FaultCode.BLE_LOST
            self.message = "bluetooth connection lost; manual resume required"
            self.state = GovernorState.FAULTED
            if self._supervisor_task and not self._supervisor_task.done():
                self._supervisor_task.cancel()

    def _on_status_tick(self, sample) -> None:
        now = asyncio.get_event_loop().time()
        self._last_telemetry_ts = now
        d_dist = (sample.distance_m or 0) - (self._prev_distance_m or 0)
        d_steps = (sample.steps or 0) - (self._prev_steps or 0)
        reset = (self._prev_distance_m is not None and (sample.distance_m or 0) < self._prev_distance_m) or (
            self._prev_steps is not None and (sample.steps or 0) < self._prev_steps
        )
        steps_delta, source = self.stepper.feed(
            self._prev_distance_m, self._prev_steps, sample.distance_m, sample.steps, sample.speed_kmh
        )
        self.recorder.log_telemetry(
            {
                "speed_kmh": sample.speed_kmh,
                "distance_m": sample.distance_m,
                "elapsed_s": sample.elapsed_s,
                "raw_steps": sample.steps,
                "steps_delta": round(steps_delta, 2),
                "step_source": source.value,
            }
        )
        if reset:
            self.recorder.log("counter_reset", {})
        if d_dist > 0 or d_steps > 0:
            self._step_off_armed = True
            self._last_progress_ts = now
        self._prev_distance_m = sample.distance_m
        self._prev_steps = sample.steps

    def _fault(self, code: FaultCode, msg: str) -> None:
        self.fault = code
        self.message = msg
        self.state = GovernorState.FAULTED
        self.recorder.log("fault", {"code": code.value, "message": msg})

    async def _supervise(self) -> None:
        loop = asyncio.get_event_loop()
        last_ramp_ts = loop.time()
        while True:
            # adaptive: ramp needs 50ms, idle can be 200ms (less CPU wake)
            delay = 0.05 if self.state is GovernorState.RAMPING else 0.2
            await asyncio.sleep(delay)
            now = loop.time()
            s = self.treadmill.status
            active = self.state in {GovernorState.RAMPING, GovernorState.RUNNING}

            if active:
                stale = now - self._last_telemetry_ts > self.config.stale_telemetry_s
                if stale:
                    self._fault(FaultCode.STALE_TELEMETRY, "telemetry stopped while belt running")
                    await self.stop()
                    return
                step_off = (
                    self._step_off_armed
                    and self.treadmill.belt_running
                    and (now - self._last_progress_ts) > self.config.step_off_timeout_s
                )
                if step_off:
                    self._fault(FaultCode.STEP_OFF, "no distance/step progress for step-off timeout")
                    await self.stop()
                    return

            if self.state is GovernorState.RAMPING and self.target_speed_kmh is not None:
                if now - last_ramp_ts >= self.config.ramp_interval_s:
                    current = s.speed_kmh or self.treadmill.min_speed
                    nxt = self.ramp.next_step(current, self.target_speed_kmh)
                    if abs(nxt - current) >= 0.05:
                        self.recorder.log("command", {"op": "ramp_step", "target": nxt})
                        try:
                            await asyncio.wait_for(
                                self.treadmill.set_speed(nxt), self.config.command_timeout_s
                            )
                        except Exception as exc:
                            self._fault(FaultCode.COMMAND_TIMEOUT, f"speed ramp failed: {exc}")
                            await self.stop()
                            return
                    elif abs(current - self.target_speed_kmh) < 0.06:
                        self.state = GovernorState.RUNNING
                    last_ramp_ts = now
