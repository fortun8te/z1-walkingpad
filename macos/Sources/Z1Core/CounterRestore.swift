import Foundation

/// Decides what can safely be carried across an app reconnect.
public struct CounterRestorePlan: Equatable, Sendable {
    public let totalKcal: Double
    public let gapElapsed: Int
    public let gapDistance: Int

    /// `savedOffset*` come from state written by builds that still had the
    /// "count across pad restarts" option. Offsets are gone, and calories
    /// accumulated against them are meaningless for the pad's own counters, so
    /// their presence only means the saved kcal must be dropped.
    public static func make(
        savedElapsed: Int,
        savedDistance: Int,
        savedOffsetElapsed: Int = 0,
        savedOffsetDistance: Int = 0,
        savedKcal: Double,
        currentElapsed: Int,
        currentDistance: Int
    ) -> Self {
        // Saved preferences are not guaranteed to have been written by this
        // build. Reject impossible counters before subtracting them, and never
        // let a non-finite saved calorie total poison all subsequent samples.
        guard savedElapsed >= 0, savedDistance >= 0,
              currentElapsed >= 0, currentDistance >= 0 else {
            return Self(totalKcal: 0, gapElapsed: 0, gapDistance: 0)
        }
        let countersRegressed = currentElapsed < savedElapsed || currentDistance < savedDistance
        // A counter regression while the app was away means the pad started a
        // new walk. The live process handles in-walk resets.
        let hadCrossSessionOffsets = savedOffsetElapsed != 0 || savedOffsetDistance != 0
        let retainedKcal = savedKcal.isFinite ? max(0, savedKcal) : 0
        return Self(
            totalKcal: (countersRegressed || hadCrossSessionOffsets) ? 0 : retainedKcal,
            gapElapsed: countersRegressed ? 0 : max(0, currentElapsed - savedElapsed),
            gapDistance: countersRegressed ? 0 : max(0, currentDistance - savedDistance)
        )
    }
}
