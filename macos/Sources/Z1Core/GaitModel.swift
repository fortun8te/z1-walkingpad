import Foundation

/// Step length from belt speed: a model fitted to one adult walker, so the
/// steps it gives are an estimate, never a measurement.
///
/// Step length (cm) = 37.038 + 8.333 × speed (km/h)
/// Steps = 100000 × km / that length
///
/// The pad's own step register is unreliable and a fixed stride is wrong:
/// slower walking is a shorter step. Belt metres and speed are the only
/// trustworthy inputs.
public enum GaitModel {
    static let interceptCm = 37.038
    static let slopeCmPerKmh = 8.333
    public static let minSpeedKmh = 0.8
    public static let maxSpeedKmh = 8.0

    public static func stepLengthM(speedKmh: Double) -> Double {
        let s = min(maxSpeedKmh, max(minSpeedKmh, speedKmh.isFinite ? speedKmh : minSpeedKmh))
        return (interceptCm + slopeCmPerKmh * s) / 100.0
    }

    public static func steps(distanceM: Int, speedKmh: Double) -> Int {
        guard distanceM > 0 else { return 0 }
        let estimate = (Double(distanceM) / stepLengthM(speedKmh: speedKmh)).rounded()
        // Corrupted restored counters must not trap during a UI conversion.
        return estimate >= Double(Int.max) ? Int.max : max(1, Int(estimate))
    }
}

/// A modelled step total for one counter run.
///
/// `ingest` accepts a treadmill update without letting a changed speed or
/// stride rewrite steps already completed: only newly travelled metres add new
/// steps, so the total never runs backwards. A distance counter that drops
/// starts a fresh run from the pad's own count.
public struct StepCounter: Sendable, Equatable {
    public private(set) var steps: Double = 0
    public var strideM: Double = 0.72
    private var lastDistanceM: Int?

    public init() {}

    public mutating func reset() {
        steps = 0
        lastDistanceM = nil
    }

    public mutating func ingest(reportedSteps: Int, distanceM: Int) {
        guard let previousDistance = lastDistanceM else {
            steps = Double(max(0, reportedSteps))
            lastDistanceM = distanceM
            return
        }
        if distanceM < previousDistance {
            steps = Double(max(0, reportedSteps))
        } else if distanceM > previousDistance {
            let stride = strideM.isFinite ? max(0.31, strideM) : 0.72
            steps += Double(distanceM - previousDistance) / stride
        }
        lastDistanceM = distanceM
    }
}
