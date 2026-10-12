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
        if let name, !name.isEmpty {
            let upper = name.uppercased()
            // The Mac's paired Windows PC advertises as DESKTOP-... . A
            // substring check for "desk" used to select it as the pad.
            if upper.hasPrefix("DESKTOP-") { return false }
            if rejectPrefixes.contains(where: { name.hasPrefix($0) || name.localizedCaseInsensitiveContains($0) }) {
                return false
            }
            // KingSmith devices sometimes omit FTMS from their advertisement.
            // Their distinctive name is sufficient; all other manufacturers
            // must advertise the service as well as a plausible treadmill name.
            if upper.hasPrefix("KS-HD") || upper.hasPrefix("KS-")
                || upper.hasPrefix("KINGSMITH") || upper.hasPrefix("WALKINGPAD") {
                return true
            }
            return ftms && (namePrefixes.contains { upper.hasPrefix($0.uppercased()) }
                || upper.contains("TREADMILL") || upper.contains("WALKING PAD"))
        }
        // Unlocking a nameless KingSmith pad is impossible; generic FTMS
        // devices also need a name before we can identify the equipment type.
        return false
    }
}
