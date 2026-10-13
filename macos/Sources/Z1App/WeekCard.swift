import SwiftUI
import Z1Core

/// Seven days as goal bars, in a card that never changes size.
///
/// ‹ › page a week at a time; clicking a bar focuses that day. Under the bars,
/// the focused day's time and distance. A new window always lands on today.
struct WeekCard: View {
    let model: TreadmillViewModel

    @State private var anchor = Date()
    @State private var selectedDay: Date?

    static let barHeight: CGFloat = 92
    static let labelHeight: CGFloat = 12

    var body: some View {
        let focused = focusedDay
        Card {
            VStack(alignment: .leading, spacing: 12) {
                titleRow(focused)
                GoalLine(model: model, day: focused)
                WeekBars(model: model, anchor: anchor, focused: focused, selectedDay: $selectedDay)
                    .frame(height: Self.barHeight + 4 + Self.labelHeight)
                DayNumbers(model: model, day: focused)
                if model.hasPendingSave(on: focused) {
                    Text("Awaiting save. Your walk is kept for retry.")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var focusedDay: Date {
        let calendar = Calendar.current
        if let selectedDay { return calendar.startOfDay(for: selectedDay) }
        return model.weekEnd(anchor, calendar: calendar)
    }

    private func titleRow(_ day: Date) -> some View {
        HStack(spacing: 4) {
            Text(title(day))
                .font(Theme.emphasis)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Spacer(minLength: 2)
            chevron("chevron.left", enabled: true, help: "Previous week") { step(-1) }
            chevron("chevron.right", enabled: model.canGoForward(from: anchor), help: "Next week") { step(1) }
        }
        .frame(height: 24)
    }

    private func title(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
    }

    private func chevron(_ symbol: String, enabled: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Theme.dim : Theme.track)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }

    private func step(_ weeks: Int) {
        if weeks > 0, !model.canGoForward(from: anchor) { return }
        anchor = model.shiftedWeek(anchor, by: weeks)
        selectedDay = nil
    }
}

// MARK: - Goal line

/// The focused day against the daily goal, as ticks: progress, so blue.
private struct GoalLine: View {
    let model: TreadmillViewModel
    let day: Date

    var body: some View {
        let totals = model.totals(for: day)
        HStack(spacing: 10) {
            TickLine(progress: model.goalProgress(for: totals), tint: Theme.accent)
                .frame(height: 9)
            Text(model.goalText(for: totals))
                .font(Theme.caption.monospacedDigit())
                .foregroundStyle(Theme.dim)
                .fixedSize()
        }
        .frame(height: 12)
    }
}

// MARK: - Numbers

private struct DayNumbers: View {
    let model: TreadmillViewModel
    let day: Date

    var body: some View {
        let totals = model.totals(for: day)
        HStack(spacing: 0) {
            StatCell(value: model.formatDuration(totals.activeDurationS), label: "Time")
            StatCell(value: model.formatDistance(totals.distanceM), label: "Distance", alignment: .trailing)
        }
    }
}

// MARK: - Bars

/// Each bar is that day's goal progress, capped at the goal. The focused day
/// is full ink, the rest a quiet grey, an empty day only its track.
private struct WeekBars: View {
    let model: TreadmillViewModel
    let anchor: Date
    let focused: Date
    @Binding var selectedDay: Date?

    var body: some View {
        let calendar = Calendar.current
        let barArea = WeekCard.barHeight
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(model.weekDays(endingOn: anchor)) { day in
                let progress = min(1, max(0, model.goalProgress(for: day)))
                let isFocused = calendar.isDate(day.day, inSameDayAs: focused)
                let isToday = calendar.isDateInToday(day.day)
                Button {
                    selectedDay = calendar.startOfDay(for: day.day)
                } label: {
                    VStack(spacing: 4) {
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Theme.wash)
                            if !day.isEmpty {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(isFocused ? Theme.ink : Theme.barRest)
                                    .frame(height: max(4, barArea * CGFloat(progress)))
                            }
                        }
                        .frame(height: barArea)
                        Text(day.day, format: .dateTime.weekday(.narrow))
                            .font(.system(size: 9, weight: isToday ? .semibold : .regular))
                            .foregroundStyle(isFocused ? Theme.ink : Theme.faint)
                            .frame(height: WeekCard.labelHeight)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(help(for: day))
                .accessibilityElement()
                .accessibilityLabel(day.day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .accessibilityValue(help(for: day))
                .accessibilityAddTraits(isFocused ? .isSelected : [])
            }
        }
    }

    private func help(for day: DayTotals) -> String {
        day.isEmpty
            ? "No walk"
            : "\(model.formatDuration(day.activeDurationS)) · \(model.formatDistance(day.distanceM))"
    }
}
