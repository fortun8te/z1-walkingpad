import Foundation

/// Step length from belt speed for this walker (185 cm, 74.3 kg, 20, male).
///
/// Step length (cm) = 37.038 + 8.333 × speed (km/h)
/// Steps = 100000 × km / that length
///
/// The pad step register is leftover junk. A fixed 53 cm stride is also
/// wrong: slower walking is a shorter step. Belt metres and average speed
/// are the only trustworthy inputs until a 200-step calibration.
public enum GaitModel {
    public static let interceptCm = 37.038
    public static let slopeCmPerKmh = 8.333
    public static let minSpeedKmh = 0.8
    public static let maxSpeedKmh = 8.0

    public static func stepLengthM(speedKmh: Double, calibratedM: Double? = nil) -> Double {
        if let calibratedM, calibratedM >= 0.35, calibratedM <= 1.10 {
            return calibratedM
        }
        let s = min(maxSpeedKmh, max(minSpeedKmh, speedKmh))
        return (interceptCm + slopeCmPerKmh * s) / 100.0
    }

    public static func steps(
        distanceM: Int,
        speedKmh: Double,
        calibratedM: Double? = nil
    ) -> Int {
        guard distanceM > 0 else { return 0 }
        let stride = stepLengthM(speedKmh: speedKmh, calibratedM: calibratedM)
        guard stride > 0 else { return 0 }
        return max(1, Int((Double(distanceM) / stride).rounded()))
    }

    public static func steps(
        distanceM: Int,
        durationS: Int,
        calibratedM: Double? = nil
    ) -> Int {
        guard distanceM > 0 else { return 0 }
        let speed = durationS > 0 ? Double(distanceM) / Double(durationS) * 3.6 : 3.0
        return steps(distanceM: distanceM, speedKmh: speed, calibratedM: calibratedM)
    }

    public static func steps(distanceKm: Double, speedKmh: Double, calibratedM: Double? = nil) -> Int {
        steps(distanceM: Int((distanceKm * 1000).rounded()), speedKmh: speedKmh, calibratedM: calibratedM)
    }
}

/// Smooths the live step counter without adding interpolation to packet totals.
/// `ingest` keeps the display monotonic within one counter run and resets it
/// when distance regresses. Interpolation never changes `packetSteps`.
public struct StepSmoother: Sendable, Equatable {
    public var packetSteps: Double = 0
    public var displaySteps: Double = 0
    public var speedKmh: Double = 0
    public var strideM: Double = 0.72
    private var lastDistanceM: Int?

    public init() {}

    public mutating func set(_ steps: Double) {
        packetSteps = max(0, steps)
        displaySteps = packetSteps
    }

    public mutating func addDelta(_ delta: Double) {
        packetSteps += max(0, delta)
        displaySteps = packetSteps
    }

    public mutating func reset() {
        packetSteps = 0
        displaySteps = 0
        lastDistanceM = nil
    }

    /// Accept a treadmill update without allowing a changed speed/stride to
    /// rewrite steps already completed. Only newly travelled metres add new
    /// steps. A real distance-counter reset starts a fresh displayed run.
    public mutating func ingest(reportedSteps: Int, distanceM: Int) {
        guard let previousDistance = lastDistanceM else {
            set(Double(reportedSteps))
            lastDistanceM = distanceM
            return
        }
        if distanceM < previousDistance {
            set(Double(reportedSteps))
        } else if distanceM > previousDistance {
            let delta = Double(distanceM - previousDistance) / max(0.31, strideM)
            packetSteps += delta
            displaySteps = max(displaySteps, packetSteps)
        }
        lastDistanceM = distanceM
    }

    /// Advance the display toward `packetSteps + expected`, never the packet total.
    public mutating func interpolate(secondsSincePacket: Double) {
        guard speedKmh > 0, strideM > 0.3 else { return }
        guard secondsSincePacket > 0.08, secondsSincePacket < 1.2 else { return }
        let expected = speedKmh / 3.6 * secondsSincePacket / strideM
        let target = packetSteps + expected
        displaySteps = max(displaySteps, min(packetSteps + 3, max(packetSteps, target)))
    }
}
