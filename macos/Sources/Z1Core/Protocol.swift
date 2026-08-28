import Foundation

/// Frame builders and parsers for the Z1 vendor supplement protocol and FTMS.
///
/// Vendor frames on the supplement channel are:
///
///     [cmd0, cmd1, len, data[len], checksum]   checksum = sum(all prior bytes) & 0xFF
///
/// All multi-byte integers are little-endian. Mirrors `protocol.py`.
public enum Z1Protocol {

    // MARK: - Vendor supplement frames

    public static func buildFrame(cmd0: UInt8, cmd1: UInt8, data: Data = Data()) -> Data {
        var body = Data([cmd0, cmd1, UInt8(data.count)])
        body.append(data)
        let sum = body.reduce(0) { ($0 + Int($1)) & 0xFF }
        body.append(UInt8(sum))
        return body
    }

    /// Parse a vendor frame -> (cmd0, cmd1, data). nil if malformed/checksum bad.
    public static func parseFrame(_ raw: Data) -> (cmd0: UInt8, cmd1: UInt8, data: Data)? {
        guard raw.count >= 4 else { return nil }
        let base = raw.startIndex
        let cmd0 = raw[base], cmd1 = raw[base + 1], length = Int(raw[base + 2])
        guard raw.count >= 3 + length + 1 else { return nil }
        let dataStart = base + 3
        let data = Data(raw[dataStart ..< dataStart + length])
        let sum = raw[base ..< dataStart + length].reduce(0) { ($0 + Int($1)) & 0xFF }
        guard sum == Int(raw[dataStart + length]) else { return nil }
        return (cmd0, cmd1, data)
    }

    /// Unlock frame: 71 00 05 01 <code LE32> CC.
    ///
    /// Code = (last 4 chars of the BLE name as a little-endian u32) + 1.
    /// For "KS-HD-Z1D" -> 71 00 05 01 2e 5a 31 44 74.
    public static func unlockFrame(deviceName: String) -> Data {
        let bytes = Array(deviceName.utf8)
        precondition(bytes.count >= 4, "device name \(deviceName) too short to derive unlock code")
        let t = Array(bytes.suffix(4))
        let code = (UInt32(t[0]) | UInt32(t[1]) << 8 | UInt32(t[2]) << 16 | UInt32(t[3]) << 24) &+ 1
        let token: [UInt8] = [
            UInt8(code & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8(code >> 24),
        ]
        let checksum = (0x71 + 0x00 + 0x05 + 0x01 + token.reduce(0) { $0 + Int($1) }) & 0xFF
        return Data([Z1Constants.vopUnlock, 0x00, 0x05, 0x01] + token + [UInt8(checksum)])
    }

    public static func isUnlockOK(_ raw: Data) -> Bool {
        guard let parsed = parseFrame(raw) else { return false }
        return parsed.cmd0 == Z1Constants.vopUnlock && parsed.cmd1 == 0x80
    }

    public static func sysInfoFrame(unixTime: UInt32, userID: UInt32 = 0) -> Data {
        var data = Data()
        data.append(contentsOf: le32(unixTime))
        data.append(contentsOf: le32(userID))
        return buildFrame(cmd0: Z1Constants.vopUnlock, cmd1: 0x01, data: data)
    }

    /// propID 0 = read all properties.
    public static func settingGetFrame(propID: UInt8 = 0) -> Data {
        buildFrame(cmd0: Z1Constants.vopProperty, cmd1: 0x00, data: Data([propID]))
    }

    /// Property write: 72 01 03 <id> <lo> <hi> CC (reply 72 81, data[1]=0 OK).
    public static func propertyWriteFrame(propID: UInt8, value: UInt16) -> Data {
        buildFrame(
            cmd0: Z1Constants.vopProperty,
            cmd1: 0x01,
            data: Data([propID, UInt8(value & 0xFF), UInt8(value >> 8)])
        )
    }

    /// Parse a SETTING_GET reply: 4-byte records [id, error, valLo, valHi].
    public static func parsePropertyRecords(_ data: Data) -> [Int: Int] {
        var props: [Int: Int] = [:]
        var i = data.startIndex
        while i + 4 <= data.endIndex {
            let pid = data[i], err = data[i + 1], lo = data[i + 2], hi = data[i + 3]
            if err == 0 {
                props[Int(pid)] = Int(lo) | (Int(hi) << 8)
            }
            i += 4
        }
        return props
    }

    private static func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
    }

    // MARK: - FTMS Treadmill Data (0x2ACD)

    public struct TreadmillData: Sendable, Equatable {
        public var speedKmh: Double?
        public var distanceM: Int?
        public var elapsedS: Int?
        public var steps: Int?
        public var calories: Int?
        public var raw: Data

        public init(
            speedKmh: Double? = nil,
            distanceM: Int? = nil,
            elapsedS: Int? = nil,
            steps: Int? = nil,
            calories: Int? = nil,
            raw: Data = Data()
        ) {
            self.speedKmh = speedKmh
            self.distanceM = distanceM
            self.elapsedS = elapsedS
            self.steps = steps
            self.calories = calories
            self.raw = raw
        }
    }

    /// Parse FTMS Treadmill Data (0x2ACD), incl. KingSmith step-count bit 13.
    public static func parseTreadmillData(_ raw: Data) -> TreadmillData {
        var out = TreadmillData(raw: raw)
        guard raw.count >= 2 else { return out }
        let flags = Int(raw[raw.startIndex]) | (Int(raw[raw.startIndex + 1]) << 8)
        var off = raw.startIndex + 2

        var truncated = false
        @discardableResult
        func take(_ n: Int) -> Data {
            let end = min(off + n, raw.endIndex)
            let chunk = Data(raw[off ..< end])
            off = end
            // A field the flags promised but the packet cannot deliver means
            // the frame arrived truncated. Decoding the missing tail as zero
            // reads downstream as a counter reset and wipes the session —
            // the whole frame must be dropped instead.
            if chunk.count < n { truncated = true }
            return chunk
        }
        func u16(_ d: Data) -> Int {
            d.count >= 2 ? Int(d[d.startIndex]) | (Int(d[d.startIndex + 1]) << 8) : 0
        }

        if flags & 0x01 == 0 { // "more data" bit clear -> instantaneous speed present
            out.speedKmh = Double(u16(take(2))) / 100
        }
        if flags & 0x02 != 0 { take(2) } // average speed
        if flags & 0x04 != 0 { // total distance, u24 meters
            let v = take(3)
            out.distanceM = v.count >= 3
                ? Int(v[0]) | (Int(v[1]) << 8) | (Int(v[2]) << 16)
                : 0
        }
        if flags & 0x08 != 0 { take(4) } // inclination + ramp angle
        if flags & 0x10 != 0 { take(2) } // elevation gain/loss
        if flags & 0x20 != 0 { take(1) } // instantaneous pace
        if flags & 0x40 != 0 { take(1) } // average pace
        if flags & 0x80 != 0 { // expended energy: total u16, per hour u16, per minute u8
            out.calories = u16(take(2))
            take(3)
        }
        if flags & 0x100 != 0 { take(1) } // heart rate
        if flags & 0x200 != 0 { take(1) } // metabolic equivalent
        if flags & 0x400 != 0 { // elapsed time
            out.elapsedS = u16(take(2))
        }
        if flags & 0x800 != 0 { take(2) } // remaining time
        if flags & 0x2000 != 0 { // KingSmith extension: step count
            out.steps = u16(take(2))
        }
        if truncated { return TreadmillData() }   // drop the frame whole
        return out
    }
}
