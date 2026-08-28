import Foundation

public enum StepSource: String, Sendable {
    case raw, estimated, calibrated, unknown
}

/// Converts sparse, integer-metre FTMS counters into a stable step total and
/// learns stride only from 12-second constant-speed windows.
public struct StepEstimator: Sendable {
    public private(set) var learner: StrideLearner
    private static let minimumWindowSeconds = 12.0
    private static let maxSpeedSpreadKmh = 0.15

    private var windowBucket: Double?
    private var windowDistance = 0.0
    private var windowSteps = 0.0
    private var windowSeconds = 0.0
    private var windowSpeedMin = Double.infinity
    private var windowSpeedMax = -Double.infinity
    private var windowSpeedSeconds = 0.0

    public init(learner: StrideLearner = StrideLearner()) {
        self.learner = learner
    }

    public var calibrated: Bool { learner.calibrated }
    public func stride(for speedKmh: Double) -> Double? { learner.stride(for: speedKmh) }

    private mutating func resetWindow() {
        windowBucket = nil
        windowDistance = 0
        windowSteps = 0
        windowSeconds = 0
        windowSpeedMin = .infinity
        windowSpeedMax = -.infinity
        windowSpeedSeconds = 0
    }

    private mutating func learnInterval(distance: Double, steps: Double, seconds: Double, speed: Double) {
        let bucket = StrideLearner.bucket(speed)
        let stable = seconds > 0 && seconds <= 5 && distance >= 0 && steps >= 0
            && speed >= StrideLearner.trustSpeedKmh
        if !stable || (windowBucket != nil && bucket != windowBucket) { resetWindow() }
        guard stable else { return }
        windowBucket = bucket
        windowDistance += distance
        windowSteps += steps
        windowSeconds += seconds
        windowSpeedMin = min(windowSpeedMin, speed)
        windowSpeedMax = max(windowSpeedMax, speed)
        windowSpeedSeconds += speed * seconds
        if windowSpeedMax - windowSpeedMin > Self.maxSpeedSpreadKmh {
            resetWindow()
            return
        }
        if windowSeconds >= Self.minimumWindowSeconds {
            learner.learn(
                distanceM: windowDistance,
                steps: windowSteps,
                speedKmh: windowSpeedSeconds / windowSeconds
            )
            resetWindow()
        }
    }

    public mutating func feed(
        previous: Z1Protocol.TreadmillData,
        current: Z1Protocol.TreadmillData,
        intervalSpeedKmh: Double?
    ) -> (delta: Double, source: StepSource) {
        guard let prevDistance = previous.distanceM, let prevSteps = previous.steps,
              let curDistance = current.distanceM, let curSteps = current.steps
        else {
            resetWindow()
            return (0, .unknown)
        }
        let dDistance = Double(curDistance - prevDistance)
        let dSteps = Double(curSteps - prevSteps)
        guard dDistance >= 0, dSteps >= 0 else {
            resetWindow()
            return (0, .unknown)
        }
        let speed = intervalSpeedKmh ?? current.speedKmh ?? 0
        if speed >= StrideLearner.trustSpeedKmh {
            let seconds = Double((current.elapsedS ?? 0) - (previous.elapsedS ?? 0))
            learnInterval(distance: dDistance, steps: dSteps, seconds: seconds, speed: speed)
            return (dSteps, calibrated ? .calibrated : .raw)
        }
        resetWindow()
        if let stride = learner.stride(for: speed) {
            return (dDistance > 0 ? dDistance / stride : 0, .calibrated)
        }
        return (dSteps, .estimated)
    }
}
