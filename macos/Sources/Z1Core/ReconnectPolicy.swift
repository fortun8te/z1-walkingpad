import Foundation

/// How hard the app looks for the pad while it is not connected.
///
/// Scanning keeps the radio busy, so it is fast only when someone is waiting
/// for it or the pad is probably right there: the window is on screen or the
/// app is frontmost, the app has just launched, the Mac has just woken, or a
/// connection has just been lost (a drop in the middle of a walk must come
/// back quickly, or the walk is cut in two). Otherwise, a pad that is simply
/// switched off gets a short look every couple of minutes.
public struct ReconnectPolicy: Equatable, Sendable {
    public enum Pace: Equatable, Sendable {
        case fast
        case slow
    }

    /// How long after launch, a wake or a lost link the pace stays fast.
    public static let fastWindow: TimeInterval = 5 * 60
    /// Slow pace: one scan of this length ...
    public static let slowScanTimeout: TimeInterval = 10
    /// ... then this long without scanning, so a cycle is about two minutes.
    public static let slowPause: TimeInterval = 110

    public let launchedAt: Date
    /// Set by the app on a wake from sleep.
    public var lastWake: Date?
    /// Set by the app when an established link goes away.
    public var lastLinkLoss: Date?

    public init(launchedAt: Date = Date()) {
        self.launchedAt = launchedAt
    }

    /// `watched`: the window is visible or the app is frontmost. A clock set
    /// back puts a start in the future; that reads as recent, so fast.
    public func pace(at now: Date, watched: Bool) -> Pace {
        if watched { return .fast }
        for start in [launchedAt, lastWake, lastLinkLoss].compactMap({ $0 })
        where now.timeIntervalSince(start) < Self.fastWindow {
            return .fast
        }
        return .slow
    }

    /// How long one scan may run.
    public static func scanTimeout(for pace: Pace) -> TimeInterval {
        switch pace {
        case .fast: Z1Constants.scanTimeout
        case .slow: slowScanTimeout
        }
    }

    /// The wait after the `attempt`-th failed try (1 for the first). Fast
    /// retries hard and then eases off to 30 s; slow is a flat pause.
    public static func pause(afterAttempt attempt: Int, pace: Pace) -> TimeInterval {
        switch pace {
        case .fast: min(30, pow(2, Double(min(max(attempt, 1), 5))))
        case .slow: slowPause
        }
    }
}
