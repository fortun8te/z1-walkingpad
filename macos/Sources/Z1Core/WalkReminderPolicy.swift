import Foundation

/// When a quiet-day reminder may be sent, and when to look again.
///
/// A reminder is a nudge, not an alarm: weekdays 9:00 to 18:00, only after
/// three quiet hours, never two inside three hours, at most two a day. Looking
/// again is scheduled for the earliest moment a reminder could be due, so an
/// idle app sleeps for hours between looks instead of polling.
public enum WalkReminderPolicy {
    /// Quiet hours before a reminder, and the minimum gap between two.
    public static let gap: TimeInterval = 3 * 3600
    public static let maxPerDay = 2
    /// How long to wait before looking again when something blocked a reminder
    /// that the clock alone cannot explain (a walk in progress).
    public static let recheckInterval: TimeInterval = 15 * 60

    private static let firstHour = 9
    private static let endHour = 18

    /// Weekday, 9:00 up to (not including) 18:00.
    public static func isReminderTime(_ date: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        let weekday = calendar.component(.weekday, from: date)
        return (firstHour..<endHour).contains(hour) && (2...6).contains(weekday)
    }

    /// Whether a reminder may go out now. `reminders` is every one already sent.
    public static func isDue(
        now: Date, lastWalkEnd: Date?, reminders: [Date], calendar: Calendar = .current
    ) -> Bool {
        guard isReminderTime(now, calendar: calendar) else { return false }
        guard now.timeIntervalSince(lastWalkEnd ?? .distantPast) >= gap else { return false }
        let today = reminders.filter { calendar.isDate($0, inSameDayAs: now) }
        guard today.count < maxPerDay else { return false }
        if let last = today.last, now.timeIntervalSince(last) < gap { return false }
        return true
    }

    /// The earliest moment after `now` at which a reminder could be due.
    public static func nextCheck(
        after now: Date, lastWalkEnd: Date?, reminders: [Date], calendar: Calendar = .current
    ) -> Date {
        var candidate = now.addingTimeInterval(recheckInterval)
        if let lastWalkEnd { candidate = max(candidate, lastWalkEnd.addingTimeInterval(gap)) }
        let today = reminders.filter { calendar.isDate($0, inSameDayAs: now) }
        if let last = today.last { candidate = max(candidate, last.addingTimeInterval(gap)) }
        if today.count >= maxPerDay {
            candidate = max(candidate, calendar.startOfDay(for: now.addingTimeInterval(86_400)))
        }
        return reminderTime(onOrAfter: candidate, calendar: calendar)
    }

    /// `date` if it is a reminder time, else the next weekday at 9:00.
    private static func reminderTime(onOrAfter date: Date, calendar: Calendar) -> Date {
        if isReminderTime(date, calendar: calendar) { return date }
        var day = calendar.startOfDay(for: date)
        for _ in 0..<8 {
            if let opening = calendar.date(bySettingHour: firstHour, minute: 0, second: 0, of: day),
               opening > date, (2...6).contains(calendar.component(.weekday, from: opening)) {
                return opening
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return date.addingTimeInterval(86_400)
    }
}
