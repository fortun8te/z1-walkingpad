import Foundation

/// The days, hours and daily cap the user chose for walk reminders.
///
/// Days are `Calendar` weekday numbers (1 Sunday ... 7 Saturday). Hours are
/// whole clock hours: reminders start at `fromHour` (0...23) and stop at
/// `untilHour` (1...24, where 24 means midnight). An `untilHour` at or before
/// `fromHour` is an overnight window, so 20 to 2 runs from 20:00 until 02:00 the
/// next morning; its tail counts as belonging to the day it started on. The
/// daily cap counts calendar days. The initialiser clamps every value, so a
/// stale or hand-edited preference can never produce an empty or inverted window.
public struct WalkReminderSchedule: Equatable, Sendable {
    public var days: Set<Int>
    public var fromHour: Int
    public var untilHour: Int
    public var perDay: Int

    /// Mon to Fri, 9:00 to 18:00, twice a day: what shipped before this was configurable.
    public static let standard = WalkReminderSchedule(days: [2, 3, 4, 5, 6], fromHour: 9, untilHour: 18, perDay: 2)

    public init(days: Set<Int>, fromHour: Int, untilHour: Int, perDay: Int) {
        let validDays = days.filter { (1...7).contains($0) }
        self.days = validDays.isEmpty ? [2, 3, 4, 5, 6] : validDays
        let from = min(23, max(0, fromHour))
        var until = min(24, max(0, untilHour))
        // A zero-length window would never open; make it one hour instead.
        if until == from { until = min(24, from + 1) }
        if until == 0 { until = 24 }
        self.fromHour = from
        self.untilHour = until
        self.perDay = min(3, max(1, perDay))
    }

    public var isOvernight: Bool { untilHour <= fromHour }

    /// Whether `hour` on a day that is itself allowed lies inside the window.
    func opens(hour: Int) -> Bool { isOvernight ? hour >= fromHour : (fromHour..<untilHour).contains(hour) }

    // MARK: stored form

    public static let daysKey = "reminderDays"
    public static let fromKey = "reminderFromHour"
    public static let untilKey = "reminderUntilHour"
    public static let perDayKey = "reminderPerDay"

    /// Reads the preferences; anything missing falls back to `standard`, so a
    /// build that never wrote them behaves exactly as before.
    public init(defaults: UserDefaults) {
        let d = Self.standard
        let stored = (defaults.array(forKey: Self.daysKey) as? [Int]).map(Set.init)
        self.init(
            days: stored ?? d.days,
            fromHour: defaults.object(forKey: Self.fromKey) as? Int ?? d.fromHour,
            untilHour: defaults.object(forKey: Self.untilKey) as? Int ?? d.untilHour,
            perDay: defaults.object(forKey: Self.perDayKey) as? Int ?? d.perDay
        )
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(days.sorted(), forKey: Self.daysKey)
        defaults.set(fromHour, forKey: Self.fromKey)
        defaults.set(untilHour, forKey: Self.untilKey)
        defaults.set(perDay, forKey: Self.perDayKey)
    }

    // MARK: plain words

    /// "Mon–Fri, 9:00–18:00, up to 2 a day"
    public var summary: String {
        "\(daysSummary), \(fromHour):00–\(untilHour % 24):00, up to \(perDay) a day"
    }

    private var daysSummary: String {
        if days.count == 7 { return "Every day" }
        let names = [2: "Mon", 3: "Tue", 4: "Wed", 5: "Thu", 6: "Fri", 7: "Sat", 1: "Sun"]
        let order = [2, 3, 4, 5, 6, 7, 1]
        var parts: [String] = []
        var run: [Int] = []
        func flush() {
            if run.count >= 3 { parts.append("\(names[run[0]]!)–\(names[run[run.count - 1]]!)") }
            else { parts.append(contentsOf: run.map { names[$0]! }) }
            run = []
        }
        for day in order {
            if days.contains(day) { run.append(day) } else { flush() }
        }
        flush()
        return parts.joined(separator: ", ")
    }
}

/// When a quiet-day reminder may be sent, and when to look again.
///
/// A reminder is a nudge, not an alarm: only on the chosen days and hours
/// (`WalkReminderSchedule`), only after three quiet hours, never two inside
/// three hours, at most the chosen number a day. Looking again is scheduled for
/// the earliest moment a reminder could be due, so an idle app sleeps for hours
/// between looks instead of polling.
public enum WalkReminderPolicy {
    /// Quiet hours before a reminder, and the minimum gap between two.
    public static let gap: TimeInterval = 3 * 3600
    /// How long to wait before looking again when something blocked a reminder
    /// that the clock alone cannot explain (a walk in progress).
    public static let recheckInterval: TimeInterval = 15 * 60

    /// Whether `date` falls on a chosen day, inside the chosen hours.
    public static func isReminderTime(
        _ date: Date, schedule: WalkReminderSchedule = .standard, calendar: Calendar = .current
    ) -> Bool {
        let hour = calendar.component(.hour, from: date)
        let weekday = calendar.component(.weekday, from: date)
        if schedule.isOvernight && hour < schedule.untilHour {
            // The small hours belong to the window that opened yesterday.
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: date) else { return false }
            return schedule.days.contains(calendar.component(.weekday, from: yesterday))
        }
        return schedule.days.contains(weekday) && schedule.opens(hour: hour)
    }

    /// Whether a reminder may go out now. `reminders` is every one already sent.
    public static func isDue(
        now: Date, lastWalkEnd: Date?, reminders: [Date],
        schedule: WalkReminderSchedule = .standard, calendar: Calendar = .current
    ) -> Bool {
        guard isReminderTime(now, schedule: schedule, calendar: calendar) else { return false }
        guard now.timeIntervalSince(lastWalkEnd ?? .distantPast) >= gap else { return false }
        let today = reminders.filter { calendar.isDate($0, inSameDayAs: now) }
        guard today.count < schedule.perDay else { return false }
        if let last = today.last, now.timeIntervalSince(last) < gap { return false }
        return true
    }

    /// The earliest moment after `now` at which a reminder could be due.
    public static func nextCheck(
        after now: Date, lastWalkEnd: Date?, reminders: [Date],
        schedule: WalkReminderSchedule = .standard, calendar: Calendar = .current
    ) -> Date {
        var candidate = now.addingTimeInterval(recheckInterval)
        if let lastWalkEnd { candidate = max(candidate, lastWalkEnd.addingTimeInterval(gap)) }
        let today = reminders.filter { calendar.isDate($0, inSameDayAs: now) }
        if let last = today.last { candidate = max(candidate, last.addingTimeInterval(gap)) }
        if today.count >= schedule.perDay {
            candidate = max(candidate, calendar.startOfDay(for: now.addingTimeInterval(86_400)))
        }
        return reminderTime(onOrAfter: candidate, schedule: schedule, calendar: calendar)
    }

    /// `date` if it is a reminder time, else the next opening of the window.
    private static func reminderTime(
        onOrAfter date: Date, schedule: WalkReminderSchedule, calendar: Calendar
    ) -> Date {
        if isReminderTime(date, schedule: schedule, calendar: calendar) { return date }
        var day = calendar.startOfDay(for: date)
        for _ in 0..<8 {
            if let opening = calendar.date(bySettingHour: schedule.fromHour, minute: 0, second: 0, of: day),
               opening > date, schedule.days.contains(calendar.component(.weekday, from: opening)) {
                return opening
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return date.addingTimeInterval(86_400)
    }
}
