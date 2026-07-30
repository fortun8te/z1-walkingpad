import Foundation

/// Unit conversions between the metric wire protocol (km/h, meters, kg) and
/// the user-facing display units (mph, miles/feet, lb). All BLE internals stay
/// metric; convert only at the UI/view-model boundary.
public enum Z1Units {
    public static func kmhToMph(_ kmh: Double) -> Double { kmh * 0.621371 }
    public static func mphToKmh(_ mph: Double) -> Double { mph / 0.621371 }

    public static func metersToMiles(_ m: Double) -> Double { m / 1609.34 }
    public static func metersToFeet(_ m: Double) -> Double { m * 3.28084 }

    public static func kgToLb(_ kg: Double) -> Double { kg * 2.20462 }
    public static func lbToKg(_ lb: Double) -> Double { lb / 2.20462 }

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
