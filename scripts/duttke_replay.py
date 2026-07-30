#!/usr/bin/env python3
"""Replay the duttke.de Web Bluetooth protocol exactly (class k / "ftms" family).

Order per working implementation:
  1. subscribe supplement notify (b00fdf7) FIRST
  2. unlock frame 71 00 05 01 <LE32(last4)+1> CC  (write WITHOUT response)
  3. on 71 80 -> SYS_INFO -> SETTING_GET all -> prop14 -> FUNC_INFO (400ms spacing)
  4. FTMS: request control 00 -> start 07 -> speed 02 (km/h*100 LE) -> stop 08 02

Belt WILL attempt to MOVE at the end. Keep clear.
"""

import asyncio
import sys
import time

sys.path.insert(0, "src")

from bleak import BleakClient, BleakScanner

DEVICE_NAME = "KS-HD-Z1D"

SUPP_SVC = "24e2521c-f63b-48ed-85be-c5330a00fdf7"
SUPP_NOTIFY = "24e2521c-f63b-48ed-85be-c5330b00fdf7"
SUPP_WRITE = "24e2521c-f63b-48ed-85be-c5330d00fdf7"

FTMS_TREADMILL_DATA = "00002acd-0000-1000-8000-00805f9b34fb"
FTMS_CONTROL_POINT = "00002ad9-0000-1000-8000-00805f9b34fb"
FTMS_MACHINE_STATUS = "00002ada-0000-1000-8000-00805f9b34fb"
FTMS_FEATURE = "00002acc-0000-1000-8000-00805f9b34fb"
FTMS_SPEED_RANGE = "00002ad4-0000-1000-8000-00805f9b34fb"

t0 = time.monotonic()


def log(msg: str) -> None:
    print(f"[{time.monotonic() - t0:7.3f}] {msg}", flush=True)


def frame(cmd0: int, cmd1: int, data: bytes) -> bytes:
    body = bytes([cmd0, cmd1, len(data)]) + data
    return body + bytes([sum(body) & 0xFF])


def unlock_frame(name: str) -> bytes:
    last4 = name[-4:].encode()
    base = int.from_bytes(last4, "little")
    n = (base + 1) & 0xFFFFFFFF
    t = n.to_bytes(4, "little")
    cc = (119 + sum(t)) & 0xFF
    return bytes([0x71, 0x00, 0x05, 0x01]) + t + bytes([cc])


class VendorWaiter:
    def __init__(self) -> None:
        self.waiters: list[tuple[callable, asyncio.Future]] = []

    def dispatch(self, data: bytes) -> None:
        log(f"RECV vendor: {data.hex(' ')}")
        for pred, fut in list(self.waiters):
            if not fut.done() and pred(data):
                fut.set_result(data)

    def wait_for(self, pred: callable, timeout: float = 3.0) -> "asyncio.Future":
        loop = asyncio.get_event_loop()
        fut = loop.create_future()
        self.waiters.append((pred, fut))
        return asyncio.wait_for(fut, timeout)


async def main() -> None:
    log("scanning...")
    device = await BleakScanner.find_device_by_name(DEVICE_NAME, timeout=15)
    if device is None:
        log("Z1 not found")
        return
    log(f"found {device.name}")

    vendor = VendorWaiter()
    unlocked = asyncio.Event()

    def on_supp_notify(_char, data: bytearray) -> None:
        b = bytes(data)
        vendor.dispatch(b)
        if len(b) >= 2 and b[0] == 0x71 and b[1] == 0x80:
            log("UNLOCK SUCCESSFUL")
            unlocked.set()

    def on_ftms_data(_char, data: bytearray) -> None:
        b = bytes(data)
        flags = int.from_bytes(b[0:2], "little")
        off = 2
        speed = dist = steps = elapsed = None
        if not flags & 0x01:
            speed = int.from_bytes(b[off:off + 2], "little") / 100
            off += 2
        if flags & 0x02:
            off += 2
        if flags & 0x04:
            dist = int.from_bytes(b[off:off + 3] + b"\x00", "little")
            off += 3
        for bit, size in ((0x08, 4), (0x10, 2), (0x20, 1), (0x40, 1), (0x80, 5), (0x100, 1), (0x200, 1)):
            if flags & bit:
                off += size
        if flags & 0x400:
            elapsed = int.from_bytes(b[off:off + 2], "little")
            off += 2
        if flags & 0x800:
            off += 2
        if flags & 0x2000:
            steps = int.from_bytes(b[off:off + 2], "little")
        log(f"TREADMILL speed={speed} dist={dist}m time={elapsed}s steps={steps}")

    def on_ftms_status(_char, data: bytearray) -> None:
        log(f"FM STATUS: {bytes(data).hex(' ')}")

    async with BleakClient(device, timeout=20) as client:
        log(f"connected, mtu={client.mtu_size}")

        # 1. supplement notify FIRST (before any vendor write)
        await client.start_notify(SUPP_NOTIFY, on_supp_notify)
        log("subscribed supplement notify")

        # FTMS telemetry subs (informational)
        for char, cb, label in (
            (FTMS_TREADMILL_DATA, on_ftms_data, "treadmill data"),
            (FTMS_MACHINE_STATUS, on_ftms_status, "machine status"),
        ):
            try:
                await client.start_notify(char, cb)
                log(f"subscribed {label}")
            except Exception as e:
                log(f"{label} subscribe failed: {e}")

        # 2. unlock — write WITHOUT response, fire-and-forget
        uf = unlock_frame(device.name)
        log(f"sending unlock: {uf.hex(' ')}")
        await client.write_gatt_char(SUPP_WRITE, uf, response=False)

        try:
            await asyncio.wait_for(unlocked.wait(), 10)
        except asyncio.TimeoutError:
            log("NO unlock response in 10s — aborting (pad stayed silent)")
            return

        # 3. initExtension sequence, 400ms spacing
        async def vendor_send(data: bytes, label: str) -> None:
            await asyncio.sleep(0.4)
            log(f"send {label}: {data.hex(' ')}")
            await client.write_gatt_char(SUPP_WRITE, data, response=False)

        now = int(time.time())
        sysinfo = frame(0x71, 0x01, now.to_bytes(4, "little") + b"\x00\x00\x00\x00")
        fut = vendor.wait_for(lambda d: len(d) > 1 and d[0] == 0x71 and d[1] == 0x81)
        await vendor_send(sysinfo, "SYS_INFO")
        try:
            resp = await fut
            d = resp[3:-1]
            log(f"SYS_INFO ok: proto={int.from_bytes(d[0:2], 'little')} caps={int.from_bytes(d[4:8], 'little'):#x}")
        except asyncio.TimeoutError:
            log("SYS_INFO timeout — no FTMS+ extension (standard FTMS only)")

        fut = vendor.wait_for(lambda d: len(d) > 1 and d[0] == 0x72 and d[1] == 0x80)
        await vendor_send(frame(0x72, 0x00, b"\x00"), "SETTING_GET all")
        try:
            resp = await fut
            d = resp[3:-1]
            for i in range(0, len(d) - 3, 4):
                pid, err, lo, hi = d[i], d[i + 1], d[i + 2], d[i + 3]
                if err == 0:
                    log(f"  prop {pid} = {lo | hi << 8} ({lo | hi << 8:#06x})")
        except asyncio.TimeoutError:
            log("SETTING_GET timeout")

        fut = vendor.wait_for(lambda d: len(d) > 2 and d[0] == 0x75 and d[1] == 0x80)
        await vendor_send(frame(0x75, 0x00, b""), "FUNC_INFO")
        try:
            resp = await fut
            d = resp[3:-1]
            if len(d) >= 12:
                log(f"FUNC_INFO ok: void={int.from_bytes(d[0:4], 'little'):#x} str={int.from_bytes(d[8:12], 'little'):#x}")
        except asyncio.TimeoutError:
            log("FUNC_INFO timeout")

        # 4. FTMS control
        feat = await client.read_gatt_char(FTMS_FEATURE)
        rng = await client.read_gatt_char(FTMS_SPEED_RANGE)
        log(f"features={feat.hex()} speed range={int.from_bytes(rng[0:2], 'little') / 100}-{int.from_bytes(rng[2:4], 'little') / 100} km/h")

        cp_results: list[bytes] = []

        def on_cp(_char, data: bytearray) -> None:
            cp_results.append(bytes(data))
            log(f"CP indicate: {bytes(data).hex(' ')}")

        await client.start_notify(FTMS_CONTROL_POINT, on_cp)

        async def cp_send(cmd: bytes, label: str) -> None:
            await asyncio.sleep(0.4)
            log(f"CP send {label}: {cmd.hex(' ')}")
            try:
                await client.write_gatt_char(FTMS_CONTROL_POINT, cmd, response=True)
            except Exception as e:
                log(f"CP write error: {e}")
            await asyncio.sleep(1.0)

        log("=== BELT CONTROL: requesting control ===")
        await cp_send(b"\x00", "REQUEST_CONTROL")
        log("=== START (belt will move) ===")
        await cp_send(b"\x07", "START")
        await asyncio.sleep(3)
        speed = (250).to_bytes(2, "little")  # 2.50 km/h, x100
        await cp_send(b"\x02" + speed, "SET_SPEED 2.5")
        log("telemetry 15s...")
        await asyncio.sleep(15)
        await cp_send(b"\x08\x02", "STOP")
        await asyncio.sleep(3)

    log("DONE")


asyncio.run(main())
