import Observation
import Z1Core

/// The pad's live numbers, one observable field each.
///
/// A view that shows the speed reads `speedKmh` and nothing else, so it does
/// not redraw when the walk clock ticks; the clock label redraws alone. This
/// is the whole performance story of the window: telemetry lands about once a
/// second while the belt moves, and only the labels whose value changed run.
@MainActor
@Observable
final class LiveState {
    private(set) var phase: Z1Treadmill.Phase = .disconnected
    private(set) var deviceName: String?
    private(set) var beltRunning = false
    private(set) var stopRequested = false
    private(set) var hasTelemetry = false
    private(set) var speedKmh = 0.0
    private(set) var elapsedS = 0
    private(set) var distanceM = 0
    private(set) var steps = 0
    private(set) var caloriesKcal = 0.0
    private(set) var minSpeedKmh = 1.6
    private(set) var maxSpeedKmh = 6.4
    private(set) var impliedStrideM: Double?
    private(set) var errorMessage: String?

    var isConnected: Bool { phase == .ready }
    var isConnecting: Bool { phase == .scanning || phase == .connecting }

    /// Copies a status frame in, writing only the fields that changed. An
    /// Observable write notifies its readers even when the value is the same.
    func apply(_ status: Z1Treadmill.Status) {
        update(\.phase, status.phase)
        update(\.deviceName, status.deviceName)
        update(\.beltRunning, status.beltRunning)
        update(\.stopRequested, status.stopRequested)
        update(\.hasTelemetry, status.hasTelemetry)
        update(\.speedKmh, status.speedKmh)
        update(\.elapsedS, status.elapsedS)
        update(\.distanceM, status.distanceM)
        update(\.steps, status.steps)
        update(\.caloriesKcal, status.caloriesKcal)
        update(\.minSpeedKmh, status.minSpeedKmh)
        update(\.maxSpeedKmh, status.maxSpeedKmh)
        update(\.impliedStrideM, status.impliedStrideM)
        update(\.errorMessage, status.errorMessage)
    }

    private func update<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<LiveState, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }
}
