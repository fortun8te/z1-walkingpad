import SwiftUI
import Z1Core

/// Day / week / month in one card that never changes size.
///
/// The chart area is one fixed box whose contents follow the lens: the day's
/// hours, the last seven days, or the month as a calendar. Under it, the
/// focused day's four numbers and one line of equivalence. Opening the panel
/// always lands on today in the week lens.
@MainActor
struct AlmanacCard: View {
    @ObservedObject var viewModel: TreadmillViewModel

    @State private var lens: TreadmillViewModel.AlmanacLens = TreadmillViewModel.isPreview
        ? TreadmillViewModel.AlmanacLens(rawValue: ProcessInfo.processInfo.environment["Z1_PREVIEW_LENS"] ?? "") ?? .week
        : .week
    @State private var anchor = Date()
    @State private var selectedDay: Date?

    private static let chartHeight: CGFloat = 92

    var body: some View {
        let totals = viewModel.totals(for: focusedDay)
        return VStack(alignment: .leading, spacing: 10) {
            titleRow
            goalRow(totals)
            chart
                .frame(height: Self.chartHeight, alignment: .top)
            HStack(spacing: 0) {
                StatCell(value: viewModel.formatDistance(totals.distanceM), label: "Distance")
                StatCell(value: viewModel.formatDuration(totals.activeDurationS), label: "Time")
                StatCell(value: totals.steps.formatted(.number), label: "Steps est.")
                StatCell(value: "\(Int(totals.caloriesKcal.rounded()))", label: "kcal est.")
            }
            Text(footer(totals))
                .font(Z1Type.regular(10))
                .foregroundStyle(Z1.dim)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .z1LiquidGlass(radius: 14)
        .z1InnerGlow(Z1.live, radius: 14, strength: 0.28, width: 10)
        .z1Card(radius: 14)
    }

    // MARK: title + lens

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(periodTitle)
                .font(Z1Type.medium(15))
                .foregroundStyle(Z1.ink)
                .lineLimit(1)
            Spacer(minLength: 4)
            chevron("chevron.left", enabled: true) { step(-1) }
            ForEach(TreadmillViewModel.AlmanacLens.allCases) { option in
                Button {
                    lens = option
                    selectedDay = nil
                    anchor = Date()
                } label: {
                    Text(option.label)
                        .font(Z1Type.regular(11))
                        .foregroundStyle(lens == option ? Z1.ink : Z1.faint)
                        .padding(.horizontal, 3)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            chevron(
                "chevron.right",
                enabled: viewModel.canGoForward(lens: lens, anchor: anchor)
            ) { step(1) }
        }
        .frame(height: 20)
    }

    private func chevron(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 16, height: 20)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Z1.dim : Z1.unlit)
        .disabled(!enabled)
    }

    private func goalRow(_ totals: DayTotals) -> some View {
        HStack(spacing: 10) {
            TickLine(progress: viewModel.goalProgress(for: totals))
            Text(viewModel.goalText(for: totals))
                .font(Z1Type.regular(11))
                .foregroundStyle(Z1.dim)
                .fixedSize()
        }
        .frame(height: 12)
    }

    // MARK: chart

    @ViewBuilder
    private var chart: some View {
        switch lens {
        case .day: hourBars
        case .week: weekBars
        case .month: monthGrid
        }
    }

    /// The day's kcal by hour. Square bars, hours 6–23 labelled sparsely.
    private var hourBars: some View {
        let bins = viewModel.hourlyKcal(for: focusedDay)
        let peak = max(bins.max() ?? 0, 1)
        let barArea = Self.chartHeight - 14
        return VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<24, id: \.self) { hour in
                    Rectangle()
                        .fill(bins[hour] > 0 ? Z1.ink.opacity(0.85) : Z1.unlit)
                        .frame(height: bins[hour] > 0 ? max(3, barArea * bins[hour] / peak) : 2)
                        .help(bins[hour] > 0 ? "\(hour):00 · \(Int(bins[hour].rounded())) kcal" : "\(hour):00")
                }
            }
            .frame(height: barArea, alignment: .bottom)
            HStack(spacing: 0) {
                ForEach([0, 6, 12, 18], id: \.self) { hour in
                    Text("\(hour)")
                        .font(Z1Type.regular(9))
                        .foregroundStyle(Z1.faint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: 10)
        }
    }

    /// Seven days ending today; each bar is that day's goal progress.
    private var weekBars: some View {
        let days = viewModel.almanacDays(lens: .week, anchor: anchor)
        let focused = focusedDay
        let barArea = Self.chartHeight - 14
        return HStack(alignment: .bottom, spacing: 5) {
            ForEach(days) { day in
                let progress = min(1, max(0, viewModel.goalProgress(for: day)))
                let isFocused = Calendar.current.isDate(day.day, inSameDayAs: focused)
                let isToday = Calendar.current.isDateInToday(day.day)
                VStack(spacing: 4) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.white.opacity(0.035))
                        if !day.isEmpty {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(isFocused ? Z1.ink.opacity(0.9) : Z1.ink.opacity(0.32))
                                .frame(height: max(3, barArea * CGFloat(progress)))
                        }
                    }
                    .frame(height: barArea)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(isFocused ? Z1.ink.opacity(0.55) : .clear, lineWidth: 0.8)
                    )
                    Text(day.day, format: .dateTime.weekday(.narrow))
                        .font(Z1Type.regular(9))
                        .foregroundStyle(isToday ? Z1.ink : Z1.faint)
                        .frame(height: 10)
                }
                .contentShape(.rect)
                .onTapGesture { selectedDay = Calendar.current.startOfDay(for: day.day) }
                .help(help(for: day))
            }
        }
    }

    /// The month as a calendar. Six fixed rows, so every month uses the same cells.
    private var monthGrid: some View {
        let days = viewModel.almanacDays(lens: .month, anchor: anchor)
        let calendar = Calendar.current
        let firstWeekday = days.first.map { calendar.component(.weekday, from: $0.day) } ?? calendar.firstWeekday
        let pad = (firstWeekday - calendar.firstWeekday + 7) % 7
        let cells: [DayTotals?] = Array(repeating: nil, count: pad) + days.map { Optional($0) }
        // Always six rows. Sizing cells to the month's own 4, 5 or 6 rows made
        // every cell change height when the chevrons crossed months.
        let rows = 6
        let cellHeight = (Self.chartHeight - 12 - CGFloat(rows - 1) * 2) / CGFloat(rows)
        let focused = focusedDay
        let symbols = calendar.veryShortWeekdaySymbols
        let start = calendar.firstWeekday - 1
        let weekdays = Array(symbols[start...] + symbols[..<start])
        return VStack(spacing: 2) {
            HStack(spacing: 3) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(Z1Type.regular(8))
                        .foregroundStyle(Z1.faint)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 10)
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 3) {
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
        let fill: Color = day.isEmpty ? Z1.unlit : Z1.ink.opacity(0.18 + 0.62 * progress)
        return ZStack {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(isFuture ? .clear : fill)
            if isFocused {
                Text("\(calendar.component(.day, from: day.day))")
                    .font(Z1Type.medium(8))
                    .foregroundStyle(progress > 0.5 ? Color.black : Z1.ink)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .overlay(
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .strokeBorder(isFocused ? Z1.ink.opacity(0.8) : .clear, lineWidth: 0.8)
        )
        .contentShape(.rect)
        .onTapGesture {
            guard !isFuture else { return }
            selectedDay = calendar.startOfDay(for: day.day)
        }
        .help(help(for: day))
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
            return Calendar.current.isDate(anchor, equalTo: Date(), toGranularity: .month)
                ? "This month"
                : anchor.formatted(.dateTime.month(.wide).year())
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
            : "\(day.activeDurationS / 60) min · \(viewModel.formatDistance(day.distanceM)) · \(day.steps) steps"
    }

    private func footer(_ totals: DayTotals) -> String {
        if totals.distanceM == 0 {
            return Equivalence.journeyLine(totalMeters: viewModel.lifetimeDistanceM)
        }
        return Equivalence.caption(
            distanceM: totals.distanceM,
            kcal: totals.caloriesKcal,
            minutes: totals.activeDurationS / 60
        )
    }
}

/// Goal progress as ticks: the app's one progress idiom.
struct TickLine: View {
    var progress: Double
    var count = 40

    var body: some View {
        Canvas { context, size in
            let pitch = size.width / CGFloat(count)
            let lit = Int((min(max(progress, 0), 1) * Double(count)).rounded(.down))
            for i in 0..<count {
                let on = i < lit
                let h = on ? size.height : size.height * 0.5
                context.fill(
                    Path(CGRect(x: CGFloat(i) * pitch, y: (size.height - h) / 2, width: 1.3, height: h)),
                    with: .color(on ? Z1.ink.opacity(0.9) : Color.white.opacity(0.16))
                )
            }
        }
    }
}
