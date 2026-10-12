import SwiftUI
import Z1Core

/// Day, week and month in one card that never changes size.
///
/// The chart box is fixed; its contents follow the lens: the day's hours, the
/// last seven days, or the month as a calendar. Under it, the focused day's
/// four numbers. Every new window lands on today.
///
/// The parts redraw on their own clocks: the goal line and the numbers with
/// every telemetry frame (they are today's live totals), the chart only when
/// a bar would visibly move, the title only when you click.
struct AlmanacCard: View {
    let model: TreadmillViewModel

    @State private var lens: TreadmillViewModel.AlmanacLens = PreviewHarness.lens ?? .week
    @State private var anchor = Date()
    @State private var selectedDay: Date?

    static let chartHeight: CGFloat = 116
    static let labelHeight: CGFloat = 12

    var body: some View {
        let focused = focusedDay
        Card {
            VStack(alignment: .leading, spacing: 12) {
                titleRow
                AlmanacGoalLine(model: model, day: focused)
                AlmanacChart(model: model, lens: lens, anchor: anchor, focused: focused, selectedDay: $selectedDay)
                    .frame(height: Self.chartHeight, alignment: .top)
                AlmanacNumbers(model: model, day: focused)
            }
        }
    }

    // MARK: title + lens

    private var titleRow: some View {
        HStack(spacing: 4) {
            Text(periodTitle)
                .font(Theme.emphasis)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 2)
            ChipPicker(
                options: TreadmillViewModel.AlmanacLens.allCases.map { ($0, $0.label) },
                selection: Binding(
                    get: { lens },
                    set: { newLens in
                        lens = newLens
                        selectedDay = nil
                        anchor = Date()
                    }
                ),
                compact: true
            )
            .fixedSize()
            chevron("chevron.left", enabled: true, help: "Earlier") { step(-1) }
            chevron(
                "chevron.right",
                enabled: model.canGoForward(lens: lens, anchor: anchor),
                help: "Later"
            ) { step(1) }
        }
        .frame(height: 26)
    }

    private func chevron(_ symbol: String, enabled: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 16, height: 24)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Theme.dim : Theme.track)
        .disabled(!enabled)
        .help(help)
    }

    // MARK: state

    private var focusedDay: Date {
        let calendar = Calendar.current
        if let selectedDay { return calendar.startOfDay(for: selectedDay) }
        if lens == .day { return calendar.startOfDay(for: anchor) }
        let today = calendar.startOfDay(for: Date())
        let start = model.periodStart(lens: lens, anchor: anchor)
        let end = model.periodEnd(lens: lens, anchor: anchor)
        if today >= start, today <= end { return today }
        return end
    }

    private var periodTitle: String {
        if lens == .month, selectedDay == nil {
            return Calendar.current.isDate(anchor, equalTo: Date(), toGranularity: .year)
                ? anchor.formatted(.dateTime.month(.wide))
                : anchor.formatted(.dateTime.month(.abbreviated).year())
        }
        let day = focusedDay
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private func step(_ delta: Int) {
        if delta > 0, !model.canGoForward(lens: lens, anchor: anchor) { return }
        anchor = model.shiftedAnchor(lens: lens, anchor: anchor, by: delta)
        selectedDay = nil
    }
}

// MARK: - Goal line

/// The focused day against the daily goal, as ticks. Progress is the second
/// thing blue means.
private struct AlmanacGoalLine: View {
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

private struct AlmanacNumbers: View {
    let model: TreadmillViewModel
    let day: Date

    var body: some View {
        let totals = model.totals(for: day)
        HStack(spacing: 0) {
            StatCell(value: model.formatDistance(totals.distanceM), label: "Distance")
            StatCell(value: model.formatDuration(totals.activeDurationS), label: "Time")
            StatCell(value: totals.steps.formatted(.number), label: "Steps est.")
            StatCell(value: "\(Int(totals.caloriesKcal.rounded()))", label: "kcal est.")
        }
    }
}

// MARK: - Chart

private struct AlmanacChart: View {
    let model: TreadmillViewModel
    let lens: TreadmillViewModel.AlmanacLens
    let anchor: Date
    let focused: Date
    @Binding var selectedDay: Date?

    private var chartHeight: CGFloat { AlmanacCard.chartHeight }
    private var labelHeight: CGFloat { AlmanacCard.labelHeight }

    var body: some View {
        switch lens {
        case .day: hourBars
        case .week: weekBars
        case .month: monthGrid
        }
    }

    /// The day's kcal by hour; every hour a thin bar, the axis marked at 0/6/12/18.
    private var hourBars: some View {
        let bins = model.hourlyKcal(for: focused)
        let peak = max(bins.max() ?? 0, 1)
        let barArea = chartHeight - labelHeight - 4
        return VStack(spacing: 4) {
            Canvas { context, size in
                let pitch = size.width / 24
                let width = max(2, pitch - 3)
                for hour in 0..<24 {
                    let value = bins[hour]
                    let h = value > 0 ? max(3, size.height * value / peak) : 2
                    let rect = CGRect(x: CGFloat(hour) * pitch + (pitch - width) / 2, y: size.height - h, width: width, height: h)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 1.5),
                        with: .color(value > 0 ? Theme.ink.opacity(0.8) : Theme.wash)
                    )
                }
            }
            .frame(height: barArea)
            HStack(spacing: 0) {
                ForEach([0, 6, 12, 18], id: \.self) { hour in
                    Text("\(hour)")
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(Theme.faint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: labelHeight)
        }
    }

    /// Seven days ending on the anchor; each bar is that day's goal progress.
    private var weekBars: some View {
        let days = model.almanacDays(lens: .week, anchor: anchor)
        let calendar = Calendar.current
        let barArea = chartHeight - labelHeight - 4
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(days) { day in
                let progress = min(1, max(0, model.goalProgress(for: day)))
                let isFocused = calendar.isDate(day.day, inSameDayAs: focused)
                let isToday = calendar.isDateInToday(day.day)
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
                        .frame(height: labelHeight)
                }
                .contentShape(.rect)
                .onTapGesture { selectedDay = calendar.startOfDay(for: day.day) }
                .help(help(for: day))
            }
        }
    }

    /// The month as a calendar: always six rows, so every month uses the
    /// same cells and crossing months never changes a cell's height.
    private var monthGrid: some View {
        let days = model.almanacDays(lens: .month, anchor: anchor)
        let calendar = Calendar.current
        let firstWeekday = days.first.map { calendar.component(.weekday, from: $0.day) } ?? calendar.firstWeekday
        let pad = (firstWeekday - calendar.firstWeekday + 7) % 7
        let cells: [DayTotals?] = Array(repeating: nil, count: pad) + days.map { Optional($0) }
        let rows = 6
        let spacing: CGFloat = 3
        let cellHeight = (chartHeight - labelHeight - 2 - CGFloat(rows - 1) * spacing) / CGFloat(rows)
        let symbols = calendar.veryShortWeekdaySymbols
        let start = calendar.firstWeekday - 1
        let weekdays = Array(symbols[start...] + symbols[..<start])
        return VStack(spacing: spacing) {
            HStack(spacing: spacing) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.faint)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: labelHeight - 1)
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: spacing) {
                    ForEach(0..<7, id: \.self) { column in
                        let index = row * 7 + column
                        if index < cells.count, let day = cells[index] {
                            monthCell(day, height: cellHeight)
                        } else {
                            Color.clear.frame(maxWidth: .infinity).frame(height: cellHeight)
                        }
                    }
                }
            }
        }
    }

    private func monthCell(_ day: DayTotals, height: CGFloat) -> some View {
        let calendar = Calendar.current
        let progress = min(1, max(0, model.goalProgress(for: day)))
        let isFocused = calendar.isDate(day.day, inSameDayAs: focused)
        let isFuture = day.day > Date()
        let fill: Color = isFuture
            ? .clear
            : (day.isEmpty ? Theme.wash : Theme.ink.opacity(0.16 + 0.66 * progress))
        return RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .strokeBorder(
                        isFocused ? Theme.ink : (isFuture ? Theme.wash : .clear),
                        lineWidth: isFocused ? 1 : 0.5
                    )
                    .padding(isFocused ? -1.5 : 0)
            )
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .contentShape(.rect)
            .onTapGesture {
                guard !isFuture else { return }
                selectedDay = calendar.startOfDay(for: day.day)
            }
            .help(isFuture ? "" : "\(day.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) · \(help(for: day))")
    }

    private func help(for day: DayTotals) -> String {
        day.isEmpty
            ? "No walk"
            : "\(day.activeDurationS / 60) min · \(model.formatDistance(day.distanceM)) · \(day.steps) steps est."
    }
}
