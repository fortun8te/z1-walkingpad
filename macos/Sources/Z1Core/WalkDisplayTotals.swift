import Foundation

/// Shared read-only totals for Today, History and the live JSON snapshot.
/// Pending logs remain owned by the tracker until a durable save succeeds.
public enum WalkDisplayTotals {
    public static func addingTrackedWalks(
        to stored: DayTotals,
        savedSessionIDs: Set<String>,
        tracker: RemoteSessionTracker,
        weightKg: Double,
        calendar: Calendar = .current
    ) -> DayTotals {
        var totals = stored
        // Track only this small overlay. Mutating a copy of savedSessionIDs
        // would copy the entire history set on every live telemetry frame.
        var counted = Set<String>()
        for walk in tracker.pendingCompletedWalks
            where !savedSessionIDs.contains(walk.id) && counted.insert(walk.id).inserted
        {
            totals.add(session(walk, weightKg: weightKg), calendar: calendar)
        }
        if let open = tracker.openWalkTotals,
           !savedSessionIDs.contains(open.id), counted.insert(open.id).inserted
        {
            let before = totals
            totals.add(session(open, weightKg: weightKg), calendar: calendar)
            // Preserve the existing open-walk rule: a zero-duration frame
            // does not create a walk count before any walking occurred.
            if totals.activeDurationS == before.activeDurationS { totals.walks = before.walks }
        }
        return totals
    }

    /// A day-specific hint disappears as soon as that walk is durably saved.
    public static func hasPendingSave(
        on day: Date,
        savedSessionIDs: Set<String>,
        tracker: RemoteSessionTracker,
        calendar: Calendar = .current
    ) -> Bool {
        for walk in tracker.pendingCompletedWalks where !savedSessionIDs.contains(walk.id) {
            var portion = DayTotals(day: day)
            portion.add(session(walk, weightKg: Z1Metrics.defaultWeightKg), calendar: calendar)
            if portion.walks > 0 { return true }
        }
        return false
    }

    private static func session(_ walk: CompletedWalk, weightKg: Double) -> WalkSession {
        let kcal = Z1Metrics.kcalPerMinute(walk.avgSpeedKmh, weightKg: weightKg)
            * Double(walk.activeDurationS) / 60
        return WalkSession(
            id: walk.id, startedAt: walk.startedAt, endedAt: walk.endedAt,
            activeDurationS: walk.activeDurationS, distanceM: walk.distanceM,
            steps: walk.steps, caloriesKcal: (kcal * 10).rounded() / 10,
            exportedToHealth: false, rawPadSteps: walk.rawPadSteps
        )
    }
}
