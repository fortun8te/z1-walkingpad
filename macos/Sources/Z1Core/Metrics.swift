import Foundation

/// Local health-metric estimation — the Z1 streams speed/distance/time/steps
/// but NOT calories, so we compute energy expenditure the same way fitness apps
/// do: the Compendium of Physical Activities MET values for level walking.
///
///     kcal/min = MET * 3.5 * weight_kg / 200
///
/// Mirrors `metrics.py`.
public enum Z1Metrics {
    /// MET by walking speed (km/h), level surface. Linear interpolation between points.
    public static let metTable: [(speed: Double, met: Double)] = [
        (0.0, 1.0), // standing
        (1.6, 2.0), // very slow walk
        (2.5, 2.8),
        (3.2, 3.0),
        (4.0, 3.5),
        (4.8, 3.8),
        (5.5, 4.3),
        (6.4, 5.0), // Z1 max speed
    ]

    public static let defaultWeightKg = 75.0

    public static func metForSpeed(_ kmh: Double) -> Double {
        if kmh <= metTable[0].speed { return metTable[0].met }
        for i in 1 ..< metTable.count {
            let (s0, m0) = metTable[i - 1]
            let (s1, m1) = metTable[i]
            if kmh <= s1 {
                let frac = (kmh - s0) / (s1 - s0)
                return m0 + frac * (m1 - m0)
            }
        }
        return metTable[metTable.count - 1].met
    }

    public static func kcalPerMinute(_ kmh: Double, weightKg: Double) -> Double {
        metForSpeed(kmh) * 3.5 * weightKg / 200
    }
}

/// Integrates calorie burn from a stream of speed samples.
public struct CalorieTracker: Sendable {
    public var weightKg: Double
    public private(set) var totalKcal = 0.0

    public init(weightKg: Double = Z1Metrics.defaultWeightKg) {
        self.weightKg = weightKg
    }

    /// Credit burn for `elapsedS` seconds spent at `speedKmh`.
    public mutating func addSample(speedKmh: Double, elapsedS: Double) {
        guard elapsedS > 0 else { return }
        totalKcal += Z1Metrics.kcalPerMinute(speedKmh, weightKg: weightKg) * (elapsedS / 60)
    }

    public mutating func reset() {
        totalKcal = 0.0
    }
}
