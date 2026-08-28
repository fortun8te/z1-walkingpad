import Foundation

/// What the man is doing. Not what the treadmill is doing -- the two come
/// apart on purpose, and the gap between them is most of the character.
enum WalkerActivity: String, Sendable, Equatable {
    /// Late, and he has been sitting a while.
    case sleeping
    /// The belt has been still long enough that the chair came in.
    case sitting
    /// Getting up. Three beats, and they are not skippable.
    case standingUp
    /// Belt moving, his legs matched to it.
    case walking
    /// Belt moving, his legs not matched to it yet.
    case catchingUp
    /// Belt stopped, but only just. He is still on his feet at the desk.
    case pausing
}

/// Everything the state machine is allowed to know.
///
/// There is deliberately no clock in here beyond `hour`. The machine never
/// asks what time it is; time arrives as `dt` on `advance`, which is what makes
/// it testable -- you can run a whole evening through it in a loop.
struct WalkerInput: Sendable, Equatable {
    var beltRunning: Bool
    var speedKmh: Double
    /// Local hour, 0...23. Only used to decide whether he is allowed to nod off.
    var hour: Int
    /// Seconds since the person last touched anything.
    var secondsIdle: Double

    init(beltRunning: Bool = false, speedKmh: Double = 0, hour: Int = 12, secondsIdle: Double = 0) {
        self.beltRunning = beltRunning
        self.speedKmh = speedKmh
        self.hour = hour
        self.secondsIdle = secondsIdle
    }
}

/// A deterministic little generator, same shape as the one the sky field uses.
///
/// Seeded, never `Double.random`. The man's fidgets have to be reproducible or
/// the animation cannot be tested and cannot be debugged -- "he drank at the
/// wrong moment" is not a bug report you can act on unless you can replay it.
struct WalkerRandom: Sendable {
    private var seed: UInt64

    init(seed: UInt64 = 0x9E37_79B9_7F4A_7C15) {
        self.seed = seed
    }

    mutating func next() -> Double {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double((seed >> 33) & 0xFF_FFFF) / Double(0xFF_FFFF)
    }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + next() * (range.upperBound - range.lowerBound)
    }

    mutating func pick<T>(_ options: [T]) -> T? {
        guard !options.isEmpty else { return nil }
        return options[min(options.count - 1, Int(next() * Double(options.count)))]
    }
}

/// The pure state machine. No views, no timers, no `Date`.
struct WalkerState: Sendable {

    // MARK: - tuning

    enum Tuning {
        /// Below this the belt counts as stopped however the hardware feels
        /// about it. Treadmills report noisy near-zero speeds while ramping.
        static let movingThreshold = 0.15

        /// How long the belt has to stay still before the chair comes in. The
        /// delay is the point: standing there for a moment after you stop is
        /// what a person does, and it gives the fidgets somewhere to live.
        static let sitAfterIdle: Double = 45

        /// Sitting this long, at an hour that counts as late, and he nods off.
        static let sleepAfterSitting: Double = 120
        static let nightStartsAt = 23
        static let nightEndsAt = 6

        /// Getting up: three drawn beats, then he is on his feet.
        static let riseBeat: Double = 0.22

        /// How fast his legs converge on the belt. A real person takes a few
        /// steps to settle into a new speed, so the cadence chases the target
        /// rather than snapping to it -- this is the whole "catching up" state.
        static let cadenceLag: Double = 1.6

        /// While cadence is further than this from target he reads as catching
        /// up rather than walking.
        static let catchUpTolerance: Double = 6

        /// Fidgets, while standing at a stopped belt.
        static let fidgetGap: ClosedRange<Double> = 6...16
        static let fidgetHold: ClosedRange<Double> = 1.4...2.8
        /// Two-frame fidgets flip at this rate.
        static let fidgetFlip: Double = 0.28

        /// Idle breathing, for the frames that have a breath pair.
        static let breathPeriod: Double = 2.6
    }

    // MARK: - observable state

    private(set) var activity: WalkerActivity = .sitting
    private(set) var frame: WalkerFrame = .sit
    /// Steps per minute his legs are actually doing.
    private(set) var cadence: Double = 0

    // MARK: - internals

    /// Position through the 8-frame cycle, in cycles. Kept as a Double and
    /// wrapped, so a speed change never makes him skip or repeat a foot.
    private var phase: Double = 0
    private var timeInActivity: Double = 0
    private var beltStillFor: Double = 0
    private var random: WalkerRandom

    private var fidget: WalkerFrame?
    private var fidgetRemaining: Double = 0
    private var untilNextFidget: Double = 0
    private var flip: Double = 0

    init(seed: UInt64 = 0x9E37_79B9_7F4A_7C15) {
        random = WalkerRandom(seed: seed)
        untilNextFidget = random.next(in: Tuning.fidgetGap)
    }

    // MARK: - cadence

    /// Steps per minute for a belt speed.
    ///
    /// Anchored on the measured figure that ordinary walking is 110-120 steps a
    /// minute at about 4.5 km/h, and that cadence rises roughly linearly with
    /// speed over the range a walking pad covers. 4 km/h lands at 104, 6 km/h
    /// at 126. Clamped at both ends so a garbage reading cannot make him
    /// sprint or freeze.
    static func cadence(forSpeedKmh speed: Double) -> Double {
        guard speed > Tuning.movingThreshold else { return 0 }
        return min(160, max(50, 60 + 11 * speed))
    }

    /// Frames per second for a cadence.
    ///
    /// The cycle is eight frames and covers TWO steps, so each step is four
    /// frames: fps = spm / 60 * 4. At 104 spm that is 6.9 fps, about 145 ms a
    /// frame, which is where hand-animated walk cycles sit.
    static func framesPerSecond(cadence: Double) -> Double {
        cadence / 15
    }

    // MARK: - advance

    /// Move the man forward by `dt` seconds.
    mutating func advance(dt: Double, input: WalkerInput) {
        guard dt > 0 else { return }
        let dt = min(dt, 0.25)      // a wedged main thread must not teleport him

        let moving = input.beltRunning && input.speedKmh > Tuning.movingThreshold
        beltStillFor = moving ? 0 : beltStillFor + dt

        let target = Self.cadence(forSpeedKmh: moving ? input.speedKmh : 0)
        // Exponential chase, frame-rate independent.
        let k = 1 - exp(-dt / Tuning.cadenceLag)
        cadence += (target - cadence) * k
        if abs(cadence - target) < 0.5 { cadence = target }

        let previous = activity
        activity = nextActivity(moving: moving, input: input)
        timeInActivity = activity == previous ? timeInActivity + dt : 0

        flip += dt
        advancePhase(dt: dt)
        advanceFidget(dt: dt)
        frame = pickFrame()
    }

    private mutating func nextActivity(moving: Bool, input: WalkerInput) -> WalkerActivity {
        if moving {
            // Coming up off the chair takes three beats and cannot be skipped.
            let wasDown = activity == .sitting || activity == .sleeping
            if wasDown { return .standingUp }
            if activity == .standingUp, timeInActivity < Tuning.riseBeat * 3 {
                return .standingUp
            }
            let settled = abs(cadence - Self.cadence(forSpeedKmh: input.speedKmh))
            return settled > Tuning.catchUpTolerance ? .catchingUp : .walking
        }

        // Belt is still. He does not drop into the chair the moment it stops.
        if beltStillFor < Tuning.sitAfterIdle { return .pausing }

        let late = input.hour >= Tuning.nightStartsAt || input.hour < Tuning.nightEndsAt
        if activity == .sleeping { return late ? .sleeping : .sitting }
        if late, activity == .sitting, timeInActivity > Tuning.sleepAfterSitting {
            return .sleeping
        }
        return .sitting
    }

    private mutating func advancePhase(dt: Double) {
        guard activity == .walking || activity == .catchingUp else {
            // Park the cycle on a contact frame so the next walk starts from a
            // real key rather than from wherever it happened to stop.
            phase = 0
            return
        }
        let fps = Self.framesPerSecond(cadence: cadence)
        phase += dt * fps / Double(WalkerFrame.walkCycle.count)
        phase -= phase.rounded(.down)
    }

    private mutating func advanceFidget(dt: Double) {
        // Fidgets only happen on his feet at a stopped belt. Every fidget pose
        // is drawn on the standing body, so firing one while he is sitting
        // would swap the whole figure for a frame -- the exact inconsistency
        // this sprite set exists to avoid.
        guard activity == .pausing else {
            fidget = nil
            fidgetRemaining = 0
            return
        }

        if fidgetRemaining > 0 {
            fidgetRemaining -= dt
            if fidgetRemaining <= 0 {
                fidget = nil
                untilNextFidget = random.next(in: Tuning.fidgetGap)
            }
            return
        }

        untilNextFidget -= dt
        guard untilNextFidget <= 0 else { return }
        fidget = random.pick([WalkerFrame.watch, .drink, .typeA])
        fidgetRemaining = random.next(in: Tuning.fidgetHold)
    }

    private func pickFrame() -> WalkerFrame {
        switch activity {
        case .walking, .catchingUp:
            let count = WalkerFrame.walkCycle.count
            let index = min(count - 1, Int(phase * Double(count)))
            return WalkerFrame.walkCycle[index]

        case .standingUp:
            let beat = Int(timeInActivity / Tuning.riseBeat)
            switch beat {
            case 0: return .rise1
            case 1: return .rise2
            default: return .rise3
            }

        case .pausing:
            if let fidget {
                // The two-frame fidgets alternate; the one-frame ones hold.
                let alternate = fidget == .typeA
                guard alternate else { return fidget }
                let on = Int(flip / Tuning.fidgetFlip) % 2 == 0
                return on ? .typeA : .typeB
            }
            // Standing still is not a freeze-frame. One cell of breath.
            let up = Int(flip / (Tuning.breathPeriod / 2)) % 2 == 0
            return up ? .stand : .standBreath

        case .sitting:
            return .sit

        case .sleeping:
            return .sleep
        }
    }
}
