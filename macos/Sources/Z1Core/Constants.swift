import CoreBluetooth
import Foundation

/// BLE constants for the KingSmith WalkingPad Z1 (FTMS + vendor supplement).
/// Mirrors `src/z1_walkingpad_mcp/constants.py`; see docs/protocol.md.
public enum Z1Constants {
    public static let deviceNamePrefix = "KS-HD-Z1"

    // Standard FTMS service (16-bit aliases expand to 0000xxxx-0000-1000-8000-00805f9b34fb)
    public static let fitnessMachineService = CBUUID(string: "1826")
    public static let charSupportedSpeedRange = CBUUID(string: "2AD4")
    public static let charTreadmillData = CBUUID(string: "2ACD")
    public static let charFitnessMachineStatus = CBUUID(string: "2ADA")
    public static let charControlPoint = CBUUID(string: "2AD9")

    // KingSmith supplement service — the unlock gate. Until the 0x71 unlock
    // handshake completes on this channel, the pad ignores ALL FTMS control
    // point commands and suppresses ALL notifications.
    public static let supplementService = CBUUID(string: "24e2521c-f63b-48ed-85be-c5330a00fdf7")
    public static let charSupplementNotify = CBUUID(string: "24e2521c-f63b-48ed-85be-c5330b00fdf7")
    public static let charSupplementWrite = CBUUID(string: "24e2521c-f63b-48ed-85be-c5330d00fdf7")

    // FTMS control point opcodes
    public static let opRequestControl: UInt8 = 0x00
    public static let opReset: UInt8 = 0x01
    public static let opSetTargetSpeed: UInt8 = 0x02
    public static let opStartOrResume: UInt8 = 0x07
    public static let opStopOrPause: UInt8 = 0x08
    public static let stopParamStop: UInt8 = 0x01
    public static let stopParamPause: UInt8 = 0x02

    // Vendor protocol opcodes (Z1 variant)
    public static let vopUnlock: UInt8 = 0x71
    public static let vopProperty: UInt8 = 0x72
    public static let vopEvent: UInt8 = 0x73
    public static let vopMethod: UInt8 = 0x75

    /// Vendor pacing: the firmware drops vendor frames sent faster than this.
    public static let vendorMinInterval: Duration = .milliseconds(400)
    /// Same for FTMS control point writes.
    public static let controlMinInterval: Duration = .milliseconds(400)

    public static let vendorResponseTimeout: TimeInterval = 3.0
    public static let unlockTimeout: TimeInterval = 10.0
    public static let scanTimeout: TimeInterval = 20.0
    public static let connectTimeout: TimeInterval = 15.0
    public static let gattOpTimeout: TimeInterval = 10.0
}
