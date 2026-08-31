import Foundation

/// Hard floor: if steps imply a stride under 25 cm, they are not a walk.
/// Rewrite from belt distance at this person's measured stride (KS Fit:
/// 53 cm at 3.5 km/h).
public enum StepSanity {
    public static let minStrideM = 0.25
    /// KS Fit / hand count at 3.5 km/h: 53 cm. Belt distance is exact; steps
    /// are distance / this stride. The pad's step register is not used.
    public static let typicalStrideM = 0.53

    public static func fromDistance(_ distanceM: Int, strideM: Double = typicalStrideM) -> Int {
        guard distanceM > 0, strideM > 0 else { return 0 }
        return max(1, Int((Double(distanceM) / strideM).rounded()))
    }

    /// Only for stored junk: if the saved count implies a <25 cm stride, it
    /// is leftover register, not a walk. Live display does not use this.
    public static func steps(_ steps: Int, distanceM: Int) -> Int {
        guard steps > 0 else { return 0 }
        if distanceM <= 0 { return 0 }
        let stride = Double(distanceM) / Double(steps)
        guard stride < minStrideM else { return steps }
        return fromDistance(distanceM)
    }
}

public enum StepSource: String, Sendable {
    case raw, estimated, calibrated, unknown
}

/// Pad step register often does not reset when elapsed/distance do.
/// Subtract the reading at session start so the live count ticks 0, 1, 2…
public struct StepSession: Equatable, Sendable {
    public var origin = 0

    public init(origin: Int = 0) { self.origin = origin }

    public func display(pad: Int) -> Int { max(0, pad - origin) }

    public mutating func ingest(
        pad: Int,
        previousPad: Int?,
        elapsedReset: Bool,
        distanceReset: Bool,
        distanceM: Int = 0
    ) -> Int {
        if elapsedReset || distanceReset {
            origin = pad
        } else if let previousPad, pad < previousPad {
            origin = 0
        } else if let previousPad, pad - previousPad > 100 {
            origin += pad - previousPad
        }
        return display(pad: pad)
    }
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

/// Smooths the 1 Hz step counter for the popover without changing the total.
///
/// Telemetry is the authority. Between packets the display is walked forward
/// from that packet's total at the current speed/stride so the number ticks
/// instead of jumping. The next packet **snaps back** to the summed deltas —
/// leftover interpolation must not be folded in, or steps accumulate ~2×.
public struct StepSmoother: Sendable, Equatable {
    public var packetSteps: Double = 0
    public var displaySteps: Double = 0
    public var speedKmh: Double = 0
    public var strideM: Double = 0.72

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
    }

    /// Advance the display toward `packetSteps + expected`, never the packet total.
    public mutating func interpolate(secondsSincePacket: Double) {
        guard speedKmh > 0, strideM > 0.3 else { return }
        guard secondsSincePacket > 0.08, secondsSincePacket < 1.2 else { return }
        let expected = speedKmh / 3.6 * secondsSincePacket / strideM
        let target = packetSteps + expected
        displaySteps = min(packetSteps + 3, max(packetSteps, target))
    }
}
