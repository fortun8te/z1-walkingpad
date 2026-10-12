import SwiftUI
import Charts
import Z1Core

/// Every lens measures minutes walked. Totals always cover the labeled range;
/// selecting a day adds a separate detail without changing those totals.
struct AlmanacCard: View {
    let model: TreadmillViewModel
    @State private var lens: TreadmillViewModel.AlmanacLens = PreviewHarness.lens ?? .week
    @State private var anchor = Date()
    @State private var selectedDate: Date?

    private var days: [DayTotals] {
        model.almanacDays(lens: lens, anchor: anchor).map { model.totals(for: $0.day) }
    }
    private var start: Date { model.periodStart(lens: lens, anchor: anchor) }
    private var end: Date { model.periodEnd(lens: lens, anchor: anchor) }
    private var today: Date { Calendar.current.startOfDay(for: Date()) }
    private var selected: DayTotals? {
        guard let selectedDate else { return nil }
        return days.first { Calendar.current.isDate($0.day, inSameDayAs: selectedDate) }
    }
    private var rangeTitle: String {
        let format = Date.FormatStyle.dateTime.day().month(.abbreviated).year()
        return lens == .day ? start.formatted(format) : "\(start.formatted(format)) – \(end.formatted(format))"
    }
    private var totalMinutes: Double { Double(days.reduce(0) { $0 + $1.activeDurationS }) / 60 }
    private var totalDistance: Int { days.reduce(0) { $0 + $1.distanceM } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Range", selection: $lens) {
                    ForEach(TreadmillViewModel.AlmanacLens.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 210)
                Spacer()
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .help("Previous range")
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(!model.canGoForward(lens: lens, anchor: anchor))
                    .help("Next range")
            }
            Text(rangeTitle).font(Theme.bodyMedium).foregroundStyle(Theme.ink)
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text("\(totalMinutes.formatted(.number.precision(.fractionLength(0...1)))) min walked")
                    .font(Theme.emphasis)
                Text(model.formatDistance(totalDistance)).font(Theme.bodyMedium)
                Spacer()
                Text("Range total").font(Theme.caption).foregroundStyle(Theme.dim)
            }
            chart
                .frame(height: 145)
            HStack {
                Text("● No walking   + Future day")
                    .font(Theme.caption).foregroundStyle(Theme.dim)
                Spacer()
                Picker("Day details", selection: $selectedDate) {
                    Text("Select a day").tag(nil as Date?)
                    ForEach(days) { day in
                        Text(day.day.formatted(.dateTime.day().month(.abbreviated)))
                            .tag(Optional(day.day))
                    }
                }
                .labelsHidden()
                .frame(width: 130)
                .accessibilityLabel("Day details")
            }
            Text(detail)
                .font(Theme.caption)
                .foregroundStyle(Theme.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: lens) { _, _ in anchor = Date(); selectedDate = nil }
        .onChange(of: selectedDate) { _, date in
            guard let date else { return }
            let day = Calendar.current.startOfDay(for: date)
            if date != day { selectedDate = day }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(days) { day in
                if day.day > today {
                    PointMark(x: .value("Day", day.day, unit: .day), y: .value("Minutes walked", 0))
                        .symbol(.cross).symbolSize(18).foregroundStyle(Theme.dim)
                        .accessibilityLabel(day.day.formatted(.dateTime.day().month(.wide).year()))
                        .accessibilityValue("Future day")
                } else if day.activeDurationS == 0 {
                    PointMark(x: .value("Day", day.day, unit: .day), y: .value("Minutes walked", 0))
                        .symbolSize(10).foregroundStyle(Theme.dim)
                        .accessibilityLabel(day.day.formatted(.dateTime.day().month(.wide).year()))
                        .accessibilityValue("No walking recorded")
                } else {
                    BarMark(x: .value("Day", day.day, unit: .day),
                            y: .value("Minutes walked", Double(day.activeDurationS) / 60))
                        .foregroundStyle(selected?.day == day.day ? Theme.ink : Theme.ink.opacity(0.65))
                        .cornerRadius(2)
                        .accessibilityLabel(day.day.formatted(.dateTime.day().month(.wide).year()))
                        .accessibilityValue("\(Double(day.activeDurationS) / 60) minutes walked")
                }
            }
            if let selected {
                RuleMark(x: .value("Selected day", selected.day, unit: .day))
                    .foregroundStyle(Theme.dim).lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
            }
        }
        .chartYScale(domain: 0...max(10, (Double(days.map(\.activeDurationS).max() ?? 0) / 60 / 30).rounded(.up) * 30))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: lens == .month ? 5 : lens == .day ? 1 : 7)) {
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) {
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel()
            }
        }
        .chartYAxisLabel("Minutes walked", position: .leading)
        .chartXSelection(value: $selectedDate)
    }

    private var detail: String {
        guard let selected else { return "Select a bar or choose a day for its exact total." }
        let date = selected.day.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        if selected.day > today { return "\(date) · Future day" }
        if selected.activeDurationS == 0 { return "\(date) · No walking recorded" }
        let minutes = (Double(selected.activeDurationS) / 60).formatted(.number.precision(.fractionLength(0...1)))
        return "\(date) · \(minutes) min · \(model.formatDistance(selected.distanceM))"
    }

    private func step(_ amount: Int) {
        anchor = model.shiftedAnchor(lens: lens, anchor: anchor, by: amount)
        selectedDate = nil
    }
}
