import SwiftUI
import Z1Core

/// Day / week / month in one card that never changes size.
///
/// The chart box is fixed; its contents follow the lens: the day's hours, the
/// last seven days, or the month as a calendar. Under it, the focused day's
/// four numbers and one line of equivalence. Every open lands on today.
@MainActor
struct AlmanacCard: View {
    @ObservedObject var viewModel: TreadmillViewModel

    @State private var lens: TreadmillViewModel.AlmanacLens = TreadmillViewModel.isPreview
        ? TreadmillViewModel.AlmanacLens(rawValue: ProcessInfo.processInfo.environment["Z1_PREVIEW_LENS"] ?? "") ?? .week
        : .week
    @State private var anchor = Date()
    @State private var selectedDay: Date?

    private static let chartHeight: CGFloat = 104
    private static let labelHeight: CGFloat = 12

    var body: some View {
        let focused = focusedDay
        let totals = viewModel.totals(for: focused)
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                titleRow
                goalRow(totals)
                chart(focused: focused)
                    .frame(height: Self.chartHeight, alignment: .top)
                HStack(spacing: 0) {
                    StatCell(value: viewModel.formatDistance(totals.distanceM), label: "Distance")
                    StatCell(value: viewModel.formatDuration(totals.activeDurationS), label: "Time")
                    StatCell(value: totals.steps.formatted(.number), label: "Steps est.")
                    StatCell(value: "\(Int(totals.caloriesKcal.rounded()))", label: "kcal est.")
                }
            }
        }
    }

    // MARK: title + lens

    private var titleRow: some View {
        HStack(spacing: 4) {
            Text(periodTitle)
                .font(Theme.emphasis)
                .foregroundStyle(Theme.paper)
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
                enabled: viewModel.canGoForward(lens: lens, anchor: anchor),
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
        .foregroundStyle(enabled ? Theme.paper62 : Theme.paper12)
        .disabled(!enabled)
        .help(help)
    }

    private func goalRow(_ totals: DayTotals) -> some View {
        HStack(spacing: 10) {
            TickLine(progress: viewModel.goalProgress(for: totals))
                .frame(height: 9)
            Text(viewModel.goalText(for: totals))
                .font(Theme.caption.monospacedDigit())
                .foregroundStyle(Theme.paper62)
                .fixedSize()
        }
        .frame(height: 12)
    }

    // MARK: chart

    @ViewBuilder
    private func chart(focused: Date) -> some View {
        switch lens {
        case .day: hourBars(focused: focused)
        case .week: weekBars(focused: focused)
        case .month: monthGrid(focused: focused)
        }
    }

    /// The day's kcal by hour; every hour a thin bar, the axis labelled at 0/6/12/18.
    private func hourBars(focused: Date) -> some View {
        let bins = viewModel.hourlyKcal(for: focused)
        let peak = max(bins.max() ?? 0, 1)
        let barArea = Self.chartHeight - Self.labelHeight - 4
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
                        with: .color(value > 0 ? Theme.paper.opacity(0.85) : Theme.paper06)
                    )
                }
            }
            .frame(height: barArea)
            HStack(spacing: 0) {
                ForEach([0, 6, 12, 18], id: \.self) { hour in
                    Text("\(hour)")
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(Theme.paper38)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: Self.labelHeight)
        }
    }

    /// Seven days ending on the anchor; each bar is that day's goal progress.
    private func weekBars(focused: Date) -> some View {
        let days = viewModel.almanacDays(lens: .week, anchor: anchor)
        let calendar = Calendar.current
        let barArea = Self.chartHeight - Self.labelHeight - 4
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(days) { day in
                let progress = min(1, max(0, viewModel.goalProgress(for: day)))
                let isFocused = calendar.isDate(day.day, inSameDayAs: focused)
                let isToday = calendar.isDateInToday(day.day)
                VStack(spacing: 4) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isFocused ? Theme.paper.opacity(0.08) : Theme.paper06.opacity(0.7))
                        if !day.isEmpty {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Theme.paper.opacity(isFocused ? 0.92 : 0.38))
                                .frame(height: max(4, barArea * CGFloat(progress)))
                        }
                    }
                    .frame(height: barArea)
                    Text(day.day, format: .dateTime.weekday(.narrow))
                        .font(.system(size: 9, weight: isToday ? .semibold : .regular))
                        .foregroundStyle(isFocused ? Theme.paper : Theme.paper38)
                        .frame(height: Self.labelHeight)
                }
                .contentShape(.rect)
                .onTapGesture { selectedDay = calendar.startOfDay(for: day.day) }
                .help(help(for: day))
            }
        }
    }

    /// The month as a calendar: always six rows, so every month uses the
    /// same cells and crossing months never changes a cell's height.
    private func monthGrid(focused: Date) -> some View {
        let days = viewModel.almanacDays(lens: .month, anchor: anchor)
        let calendar = Calendar.current
        let firstWeekday = days.first.map { calendar.component(.weekday, from: $0.day) } ?? calendar.firstWeekday
        let pad = (firstWeekday - calendar.firstWeekday + 7) % 7
        let cells: [DayTotals?] = Array(repeating: nil, count: pad) + days.map { Optional($0) }
        let rows = 6
        let spacing: CGFloat = 3
        let cellHeight = (Self.chartHeight - Self.labelHeight - 2 - CGFloat(rows - 1) * spacing) / CGFloat(rows)
        let symbols = calendar.veryShortWeekdaySymbols
        let start = calendar.firstWeekday - 1
        let weekdays = Array(symbols[start...] + symbols[..<start])
        return VStack(spacing: spacing) {
            HStack(spacing: spacing) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.paper38)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: Self.labelHeight - 1)
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: spacing) {
                    ForEach(0..<7, id: \.self) { column in
                        let index = row * 7 + column
                        if index < cells.count, let day = cells[index] {
                            monthCell(day, focused: focused, height: cellHeight)
                        } else {
                            Color.clear.frame(maxWidth: .infinity).frame(height: cellHeight)
                        }
                    }
                }
            }
        }
    }

    private func monthCell(_ day: DayTotals, focused: Date, height: CGFloat) -> some View {
        let calendar = Calendar.current
        let progress = min(1, max(0, viewModel.goalProgress(for: day)))
        let isFocused = calendar.isDate(day.day, inSameDayAs: focused)
        let isFuture = day.day > Date()
        let fill: Color = isFuture
            ? .clear
            : (day.isEmpty ? Theme.paper06 : Theme.paper.opacity(0.22 + 0.66 * progress))
        return RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .strokeBorder(
                        isFocused ? Theme.paper : (isFuture ? Theme.paper06 : .clear),
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

    // MARK: state

    private var focusedDay: Date {
        let calendar = Calendar.current
        if let selectedDay { return calendar.startOfDay(for: selectedDay) }
        if lens == .day { return calendar.startOfDay(for: anchor) }
        let today = calendar.startOfDay(for: Date())
        let start = viewModel.periodStart(lens: lens, anchor: anchor)
        let end = viewModel.periodEnd(lens: lens, anchor: anchor)
        if today >= start, today <= end { return today }
        return end
    }

    private var periodTitle: String {
        if lens == .month, selectedDay == nil {
            let calendar = Calendar.current
            return calendar.isDate(anchor, equalTo: Date(), toGranularity: .year)
                ? anchor.formatted(.dateTime.month(.wide))
                : anchor.formatted(.dateTime.month(.abbreviated).year())
        }
        return dayTitle(focusedDay)
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    private func step(_ delta: Int) {
        if delta > 0, !viewModel.canGoForward(lens: lens, anchor: anchor) { return }
        anchor = viewModel.shiftedAnchor(lens: lens, anchor: anchor, by: delta)
        selectedDay = nil
    }

    private func help(for day: DayTotals) -> String {
        day.isEmpty
            ? "No walk"
            : "\(day.activeDurationS / 60) min · \(viewModel.formatDistance(day.distanceM)) · \(day.steps) steps est."
    }
}
