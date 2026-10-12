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
        let countersRegressed = currentElapsed < savedElapsed || currentDistance < savedDistance
        // A counter regression while the app was away means the pad started a
        // new walk. The live process handles in-walk resets.
        let hadCrossSessionOffsets = savedOffsetElapsed > 0 || savedOffsetDistance > 0
        return Self(
            totalKcal: (countersRegressed || hadCrossSessionOffsets) ? 0 : savedKcal,
            gapElapsed: countersRegressed ? 0 : max(0, currentElapsed - savedElapsed),
            gapDistance: countersRegressed ? 0 : max(0, currentDistance - savedDistance)
        )
    }
}
