import Foundation

/// Local health-metric estimation — the Z1 streams speed/distance/time/steps
/// but NOT calories, so we compute energy expenditure with the **ACSM walking
/// metabolic equation** (level grade), the exercise-physiology standard:
///
///     VO2 (ml/kg/min) = 0.1 * speed(m/min) + 3.5        (grade = 0)
///     kcal/min        = VO2 * weight_kg / 200           (5 kcal per L O2)
///
/// Best validated for ~3-6 km/h; expect ~±13% error in field conditions.
/// Mirrors `metrics.py`.
public enum Z1Metrics {
    public static let defaultWeightKg = 75.0

    /// Resting component (3.5 ml/kg/min = 1 MET).
    static let restingVO2 = 3.5
    /// Walking economy: 0.1 ml/kg/min per m/min on level ground.
    static let speedCoeff = 0.1

    /// Gross VO2 (ml/kg/min) per the ACSM level-walking equation.
    public static func vo2ForSpeed(_ kmh: Double) -> Double {
        let speedMPerMin = max(0.0, kmh) * 1000 / 60
        return speedCoeff * speedMPerMin + restingVO2
    }

    public static func metForSpeed(_ kmh: Double) -> Double {
        vo2ForSpeed(kmh) / restingVO2
    }

    public static func kcalPerMinute(_ kmh: Double, weightKg: Double) -> Double {
        vo2ForSpeed(kmh) * weightKg / 200
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
