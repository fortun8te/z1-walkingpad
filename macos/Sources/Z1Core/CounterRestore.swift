import Foundation

/// Decides what can safely be carried across an app reconnect.
public struct CounterRestorePlan: Equatable, Sendable {
    public let offsetElapsed: Int
    public let offsetDistance: Int
    public let totalKcal: Double
    public let gapElapsed: Int
    public let gapDistance: Int

    public static func make(
        persistStats: Bool,
        savedElapsed: Int,
        savedDistance: Int,
        savedOffsetElapsed: Int,
        savedOffsetDistance: Int,
        savedKcal: Double,
        currentElapsed: Int,
        currentDistance: Int
    ) -> Self {
        let countersRegressed = currentElapsed < savedElapsed || currentDistance < savedDistance
        let offsetElapsed: Int
        let offsetDistance: Int
        let totalKcal: Double
        if persistStats {
            offsetElapsed = savedOffsetElapsed + (countersRegressed ? savedElapsed : 0)
            offsetDistance = savedOffsetDistance + (countersRegressed ? savedDistance : 0)
            totalKcal = savedKcal
        } else {
            // Offsets are an explicit cross-session feature. Never resurrect
            // them merely because the app relaunched or reconnected.
            offsetElapsed = 0
            offsetDistance = 0
            // A counter regression while the app was away means the pad
            // started a new walk. The live process handles in-walk resets.
            let hadCrossSessionOffsets = savedOffsetElapsed > 0 || savedOffsetDistance > 0
            totalKcal = (countersRegressed || hadCrossSessionOffsets) ? 0 : savedKcal
        }
        return Self(
            offsetElapsed: offsetElapsed,
            offsetDistance: offsetDistance,
            totalKcal: totalKcal,
            gapElapsed: countersRegressed ? 0 : max(0, currentElapsed - savedElapsed),
            gapDistance: countersRegressed ? 0 : max(0, currentDistance - savedDistance)
        )
    }
}
