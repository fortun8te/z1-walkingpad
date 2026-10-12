import Foundation

/// Unit conversions between the metric wire protocol (km/h, meters) and the
/// user-facing display units (mph, miles/feet). All BLE internals stay metric;
/// convert only at the UI/view-model boundary.
public enum Z1Units {
    // Exact international definitions, so a round trip and a stack of
    // conversions (km/h to mph to a 0.1 step and back) never drift.
    public static let metersPerMile = 1609.344
    public static let feetPerMeter = 1 / 0.3048

    public static func kmhToMph(_ kmh: Double) -> Double { kmh * 1000 / metersPerMile }
    public static func mphToKmh(_ mph: Double) -> Double { mph * metersPerMile / 1000 }

    public static func metersToMiles(_ m: Double) -> Double { m / metersPerMile }
    public static func metersToFeet(_ m: Double) -> Double { m * feetPerMeter }

    /// Pad-side display units, per the docs/protocol.md property table:
    /// property 1 is "units / screen language"; bit 1 (0x0002) set = miles,
    /// clear = km. All other bits are preserved.
    public static func displayUnitsValue(current: Int, imperial: Bool) -> Int {
        imperial ? current | 0x0002 : current & ~0x0002
    }

    /// True if a property-1 value has the miles bit set.
    public static func propertyIndicatesImperial(_ property1: Int) -> Bool {
        property1 & 0x0002 != 0
    }
}
