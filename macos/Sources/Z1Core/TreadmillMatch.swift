import CoreBluetooth
import Foundation

/// Which BLE devices this app will talk to.
///
/// KingSmith WalkingPads need a vendor unlock. Everything else here is
/// treated as a standard FTMS treadmill (service 0x1826): start/stop/speed
/// on the control point, telemetry on Treadmill Data. Indoor bikes are
/// excluded by name.
public enum TreadmillMatch {
    public static let namePrefixes = [
        "KS-HD", "KS-", "WalkingPad", "WALKINGPAD", "KingSmith", "KINGSMITH",
        "UREVO", "Urevo", "DeerRun", "DEERUN", "Sperax", "SPERAX",
        "Egofit", "EGOFIT", "Xiaomi", "YPOO", "Lifespan", "HORIZON",
        "Sunny", "SUNNY", "Goplus", "GOPLUS", "Trailviber", "CITYSPORTS",
        "WalkingPad", "Desk Tread", "Under Desk",
    ]

    public static let rejectPrefixes = [
        "KICKR", "Wahoo", "WAHOO", "Wattbike", "Stages", "Peloton Bike",
        "Schwinn", "Keiser", "Assioma", "Tacx", "Elite ", "Neo 2",
    ]

    public static func accepts(name: String?, serviceUUIDs: [CBUUID]) -> Bool {
        let ftms = serviceUUIDs.contains(Z1Constants.fitnessMachineService)
        if let name {
            if rejectPrefixes.contains(where: { name.hasPrefix($0) || name.localizedCaseInsensitiveContains($0) }) {
                return false
            }
            if namePrefixes.contains(where: { name.hasPrefix($0) || name.localizedCaseInsensitiveContains($0) }) {
                return true
            }
            let lower = name.lowercased()
            if lower.contains("tread") || lower.contains("walk") || lower.contains("desk") {
                return true
            }
        }
        return ftms
    }
}
