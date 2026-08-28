"""Frame builders and parsers for the Z1 vendor supplement protocol and FTMS.

Vendor frames on the supplement channel are::

    [cmd0, cmd1, len, data[len], checksum]   checksum = sum(all prior bytes) & 0xFF

All multi-byte integers are little-endian.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from . import constants as c


def build_frame(cmd0: int, cmd1: int, data: bytes = b"") -> bytes:
    body = bytes([cmd0, cmd1, len(data)]) + data
    return body + bytes([sum(body) & 0xFF])


def parse_frame(raw: bytes) -> tuple[int, int, bytes] | None:
    """Parse a vendor frame -> (cmd0, cmd1, data). None if malformed/checksum bad."""
    if len(raw) < 4:
        return None
    cmd0, cmd1, length = raw[0], raw[1], raw[2]
    if len(raw) < 3 + length + 1:
        return None
    data = raw[3 : 3 + length]
    if (sum(raw[: 3 + length]) & 0xFF) != raw[3 + length]:
        return None
    return cmd0, cmd1, data


def unlock_frame(device_name: str) -> bytes:
    """Unlock frame: 71 00 05 01 <code LE32> CC.

    Code = (last 4 chars of the BLE name as a little-endian u32) + 1.
    For "KS-HD-Z1D" -> 71 00 05 01 2e 5a 31 44 74.
    """
    last4 = device_name[-4:].encode()
    if len(last4) < 4:
        raise ValueError(f"device name {device_name!r} too short to derive unlock code")
    code = (int.from_bytes(last4, "little") + 1) & 0xFFFFFFFF
    t = code.to_bytes(4, "little")
    checksum = (0x71 + 0x00 + 0x05 + 0x01 + sum(t)) & 0xFF
    return bytes([c.VOP_UNLOCK, 0x00, 0x05, 0x01]) + t + bytes([checksum])


def is_unlock_ok(raw: bytes) -> bool:
    parsed = parse_frame(raw)
    return parsed is not None and parsed[0] == c.VOP_UNLOCK and parsed[1] == 0x80


def sysinfo_frame(unix_time: int, user_id: int = 0) -> bytes:
    return build_frame(c.VOP_UNLOCK, 0x01, unix_time.to_bytes(4, "little") + user_id.to_bytes(4, "little"))


def setting_get_frame(prop_id: int = 0) -> bytes:
    """prop_id 0 = read all properties."""
    return build_frame(c.VOP_PROPERTY, 0x00, bytes([prop_id]))


def property_write_frame(prop_id: int, value: int) -> bytes:
    return build_frame(c.VOP_PROPERTY, 0x01, bytes([prop_id]) + value.to_bytes(2, "little"))


def func_info_frame() -> bytes:
    return build_frame(c.VOP_METHOD, 0x00)


def parse_property_records(data: bytes) -> dict[int, int]:
    """Parse a SETTING_GET reply: 4-byte records [id, error, valLo, valHi]."""
    props: dict[int, int] = {}
    for i in range(0, len(data) - 3, 4):
        pid, err, lo, hi = data[i], data[i + 1], data[i + 2], data[i + 3]
        if err == 0:
            props[pid] = lo | (hi << 8)
    return props


@dataclass
class TreadmillData:
    speed_kmh: float | None = None
    distance_m: int | None = None
    elapsed_s: int | None = None
    steps: int | None = None
    calories: int | None = None
    raw: bytes = field(default=b"", repr=False)


def parse_treadmill_data(raw: bytes) -> TreadmillData:
    """Parse FTMS Treadmill Data (0x2ACD), incl. KingSmith step-count bit 13."""
    out = TreadmillData(raw=bytes(raw))
    if len(raw) < 2:
        return out
    flags = int.from_bytes(raw[0:2], "little")
    off = 2

    def take(n: int) -> bytes:
        nonlocal off
        if off + n > len(raw):
            raise IndexError("FTMS frame truncated before a flagged field")
        chunk = raw[off : off + n]
        off += n
        return chunk

    try:
        if not flags & 0x01:  # "more data" bit clear -> instantaneous speed present
            out.speed_kmh = int.from_bytes(take(2), "little") / 100
        if flags & 0x02:  # average speed
            take(2)
        if flags & 0x04:  # total distance, u24 meters
            out.distance_m = int.from_bytes(take(3) + b"\x00", "little")
        if flags & 0x08:  # inclination + ramp angle
            take(4)
        if flags & 0x10:  # elevation gain/loss
            take(2)
        if flags & 0x20:  # instantaneous pace
            take(1)
        if flags & 0x40:  # average pace
            take(1)
        if flags & 0x80:  # expended energy: total u16, per hour u16, per minute u8
            out.calories = int.from_bytes(take(2), "little")
            take(3)
        if flags & 0x100:  # heart rate
            take(1)
        if flags & 0x200:  # metabolic equivalent
            take(1)
        if flags & 0x400:  # elapsed time
            out.elapsed_s = int.from_bytes(take(2), "little")
        if flags & 0x800:  # remaining time
            take(2)
        if flags & 0x2000:  # KingSmith extension: step count
            out.steps = int.from_bytes(take(2), "little")
    except IndexError:
        # Truncated FTMS frame: drop it whole rather than decoding the missing
        # tail as zero (a fake counter reset would wipe calories/steps).
        pass
    return out
