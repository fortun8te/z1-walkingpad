import AppKit
import SwiftUI
import Z1Core

/// A secondary page: the same 24 pt header line as Now, then content that
/// scrolls inside the fixed panel if it has to.
struct PageScaffold<Content: View>: View {
    var title: String
    var trailing: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.inner) {
            PageHeader {
                Text(title)
                    .font(Theme.emphasis)
                    .foregroundStyle(Theme.paper)
            } trailing: {
                if let trailing {
                    Text(trailing)
                        .font(Theme.caption.monospacedDigit())
                        .foregroundStyle(Theme.paper38)
                        .lineLimit(1)
                }
            }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Theme.related) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, Theme.related)
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            // Content leaves under a short fade instead of a hard cut.
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 14)
                }
            }
        }
    }
}

/// Plain explanatory text in a page.
struct Note: View {
    var text: String
    var body: some View {
        Text(text)
            .font(Theme.caption)
            .foregroundStyle(Theme.paper38)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Intro

/// Shown once. Three lines, one button.
struct IntroPage: View {
    var onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer(minLength: 0)
            Text("Walk.\nDon't think about it.")
                .font(Theme.section)
                .foregroundStyle(Theme.paper)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Theme.inner) {
                line("Close the phone app. The pad takes one connection.")
                line("\(GlobalHotKey.display) starts and stops from anywhere.")
            }
            Spacer(minLength: 0)
            PrimaryButton(title: "Continue", action: onContinue)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.bottom, 6)
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(Theme.body)
            .foregroundStyle(Theme.paper62)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - History

@MainActor
struct HistoryPage: View {
    @ObservedObject var viewModel: TreadmillViewModel

    var body: some View {
        let walks = viewModel.recentWalks
        PageScaffold(title: "History") {
            if walks.isEmpty {
                Note(text: "No walks yet.")
            } else {
                ForEach(groups(walks), id: \.day) { group in
                    GroupLabel(text: dayTitle(group.day))
                    Card(padding: 0, glass: false) {
                        VStack(spacing: 0) {
                            ForEach(Array(group.walks.enumerated()), id: \.element.id) { index, walk in
                                if index > 0 { RowDivider().padding(.leading, Theme.inner) }
                                row(walk)
                            }
                        }
                    }
                }
            }
        }
    }

    private func row(_ walk: WalkSession) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.related) {
            VStack(alignment: .leading, spacing: 2) {
                Text(walk.startedAt, format: .dateTime.hour().minute())
                    .font(Theme.bodyMedium.monospacedDigit())
                    .foregroundStyle(Theme.paper)
                Text("\(walk.steps.formatted()) steps est. · \(Int(walk.caloriesKcal.rounded())) kcal est.")
                    .font(Theme.caption.monospacedDigit())
                    .foregroundStyle(Theme.paper38)
            }
            Spacer(minLength: Theme.related)
            VStack(alignment: .trailing, spacing: 2) {
                Text(viewModel.formatDuration(walk.activeDurationS))
                    .font(Theme.bodyMedium.monospacedDigit())
                    .foregroundStyle(Theme.paper)
                Text(viewModel.formatDistance(walk.distanceM))
                    .font(Theme.caption.monospacedDigit())
                    .foregroundStyle(Theme.paper62)
            }
        }
        .padding(.horizontal, Theme.inner)
        .padding(.vertical, 9)
    }

    private struct DayGroup { let day: Date; let walks: [WalkSession] }

    /// Newest day first, newest walk first inside a day.
    private func groups(_ walks: [WalkSession]) -> [DayGroup] {
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: walks) { calendar.startOfDay(for: $0.startedAt) }
        return byDay.keys.sorted(by: >).map { day in
            DayGroup(day: day, walks: byDay[day, default: []].sorted { $0.startedAt > $1.startedAt })
        }
    }

    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

// MARK: - Records

@MainActor
struct RecordsPage: View {
    @ObservedObject var viewModel: TreadmillViewModel

    var body: some View {
        let hs = viewModel.highScores
        PageScaffold(
            title: "Records",
            trailing: hs.totalWalks > 0 ? "\(hs.totalWalks) walks · \(viewModel.formatDistance(hs.totalDistanceM))" : nil
        ) {
            if hs.totalWalks == 0 {
                Note(text: "No records yet.")
            } else {
                GroupLabel(text: "Best walk")
                Card(padding: 0, glass: false) {
                    VStack(spacing: 0) {
                        rows([
                            hs.longestWalk.map { ("Longest", viewModel.formatDuration($0.activeDurationS), $0.startedAt) },
                            hs.farthestWalk.map { ("Farthest", viewModel.formatDistance($0.distanceM), $0.startedAt) },
                            hs.mostStepsWalk.map { ("Most steps est.", $0.steps.formatted(), $0.startedAt) },
                        ])
                    }
                }
                GroupLabel(text: "Best day")
                Card(padding: 0, glass: false) {
                    VStack(spacing: 0) {
                        rows([
                            hs.longestDayTime.map { ("Time", viewModel.formatDuration($0.activeDurationS), $0.day) },
                            hs.mostDistanceDay.map { ("Distance", viewModel.formatDistance($0.distanceM), $0.day) },
                            hs.mostStepsDay.map { ("Steps est.", $0.steps.formatted(), $0.day) },
                            hs.bestStreakDays > 1 ? ("Streak", "\(hs.bestStreakDays) days", nil) : nil,
                        ])
                    }
                }
                GroupLabel(text: "Badges")
                badges
            }
        }
    }

    @ViewBuilder
    private func rows(_ items: [(String, String, Date?)?]) -> some View {
        let present = items.compactMap { $0 }
        ForEach(Array(present.enumerated()), id: \.offset) { index, item in
            if index > 0 { RowDivider().padding(.leading, Theme.inner) }
            HStack(alignment: .firstTextBaseline, spacing: Theme.related) {
                Text(item.0)
                    .font(Theme.body)
                    .foregroundStyle(Theme.paper62)
                Spacer(minLength: Theme.related)
                if let date = item.2 {
                    Text(date, format: .dateTime.day().month(.abbreviated))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.paper38)
                }
                Text(item.1)
                    .font(Theme.bodyMedium.monospacedDigit())
                    .foregroundStyle(Theme.paper)
                    .frame(minWidth: 70, alignment: .trailing)
            }
            .padding(.horizontal, Theme.inner)
            .frame(height: 34)
        }
    }

    private var badges: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: Theme.related), GridItem(.flexible(), spacing: Theme.related)],
            spacing: Theme.related
        ) {
            ForEach(viewModel.achievements) { ach in
                VStack(alignment: .leading, spacing: 7) {
                    Text(ach.kind.title)
                        .font(Theme.captionMedium)
                        .foregroundStyle(ach.unlocked ? Theme.paper : Theme.paper62)
                        .lineLimit(1)
                    TickLine(progress: ach.progress, count: 26)
                        .frame(height: 7)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(ach.kind.description)
            }
        }
    }
}

// MARK: - Settings

@MainActor
struct SettingsPage: View {
    @ObservedObject var viewModel: TreadmillViewModel
    @ObservedObject private var sky = SkyEngine.shared
    @State private var weightDraft = ""
    @FocusState private var weightFocused: Bool

    var body: some View {
        PageScaffold(title: "Settings") {
            GroupLabel(text: "Walking")
            Card(padding: 0, glass: false) {
                VStack(spacing: 0) {
                    cell { goalRow }
                    divider
                    cell {
                        SettingRow(title: "Speed per − / +") {
                            ChipPicker(options: [(0.1, "0.1"), (0.2, "0.2"), (0.5, "0.5")], selection: $viewModel.speedStep, compact: true)
                        }
                    }
                    divider
                    cell {
                        SettingRow(title: "Units") {
                            ChipPicker(options: [(false, "Metric"), (true, "Imperial")], selection: $viewModel.unitsImperial, compact: true)
                        }
                    }
                    divider
                    cell { weightRow }
                    divider
                    cell {
                        Toggle(isOn: $viewModel.useHealthWeight) { label("Weight from Apple Health") }
                            .toggleStyle(PillToggleStyle())
                    }
                }
            }

            GroupLabel(text: "Menu bar")
            Card(padding: 0, glass: false) {
                VStack(spacing: 0) {
                    cell {
                        SettingRow(title: "Beside the icon") {
                            Picker("", selection: $viewModel.menuBarReadout) {
                                ForEach(MenuBarReadout.allCases) { readout in
                                    Text(readout.label).tag(readout)
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .fixedSize()
                        }
                    }
                    divider
                    cell {
                        Toggle(isOn: $viewModel.menuBarAlwaysVisible) { label("Show it while the belt is stopped") }
                            .toggleStyle(PillToggleStyle())
                            .disabled(viewModel.menuBarReadout == .none)
                    }
                    divider
                    cell {
                        Toggle(isOn: $viewModel.globalShortcutEnabled) {
                            label("\(GlobalHotKey.display) starts and stops")
                        }
                        .toggleStyle(PillToggleStyle())
                    }
                }
            }

            GroupLabel(text: "Notifications")
            Card(padding: 0, glass: false) {
                VStack(spacing: 0) {
                    cell {
                        Toggle(isOn: $viewModel.notificationsEnabled) { label("When a walk is recorded") }
                            .toggleStyle(PillToggleStyle())
                    }
                    divider
                    cell {
                        Toggle(isOn: $viewModel.remindersEnabled) { label("Remind me on quiet days") }
                            .toggleStyle(PillToggleStyle())
                    }
                    divider
                    cell {
                        SettingRow(title: "Quiet for") {
                            ChipPicker(options: [(2, "2h"), (3, "3h"), (4, "4h")], selection: $viewModel.reminderGapHours, compact: true)
                                .disabled(!viewModel.remindersEnabled)
                                .opacity(viewModel.remindersEnabled ? 1 : 0.4)
                        }
                    }
                }
            }

            GroupLabel(text: "Steps")
            Card(padding: 0, glass: false) {
                VStack(spacing: 0) {
                    cell {
                        SettingRow(title: "Stride") {
                            Text(viewModel.strideLabel)
                                .font(Theme.body.monospacedDigit())
                                .foregroundStyle(Theme.paper62)
                        }
                    }
                    divider
                    cell {
                        HStack(spacing: Theme.related) {
                            Toggle(isOn: $viewModel.persistStats) { label("Count across pad restarts") }
                                .toggleStyle(PillToggleStyle())
                            Button("Clear") { viewModel.clearStatsTapped() }
                                .buttonStyle(SecondaryButtonStyle())
                                .disabled(!viewModel.persistStats)
                        }
                    }
                }
            }

            GroupLabel(text: "Outside")
            Card(glass: false) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(sky.conditions.summary)
                        .font(Theme.body)
                        .foregroundStyle(Theme.paper)
                        .fixedSize(horizontal: false, vertical: true)
                    if let next = sky.conditions.nextEvent {
                        Text(next)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.paper62)
                    }
                }
            }

            GroupLabel(text: "App")
            Card(padding: 0, glass: false) {
                VStack(spacing: 0) {
                    cell {
                        Toggle(isOn: $viewModel.launchAtLogin) { label("Start at login", viewModel.loginItemMessage) }
                            .toggleStyle(PillToggleStyle())
                    }
                    divider
                    cell {
                        Toggle(isOn: $viewModel.autoUpdate) { label("Install updates automatically") }
                            .toggleStyle(PillToggleStyle())
                    }
                    divider
                    cell {
                        SettingRow(title: viewModel.status.deviceName ?? "Pad") {
                            Button(viewModel.isConnected ? "Disconnect" : "Connect") { viewModel.connectTapped() }
                                .buttonStyle(SecondaryButtonStyle())
                                .disabled(viewModel.busy || viewModel.isConnecting)
                        }
                    }
                }
            }

            HStack(spacing: Theme.related) {
                Button { viewModel.quit() } label: { wide("Quit") }
                    .buttonStyle(PrimaryButtonStyle())
                    .help("Quit and leave the belt exactly as it is (⌘Q)")
                Button { viewModel.stopBeltAndQuit() } label: { wide("Stop pad and quit") }
                    .buttonStyle(PrimaryButtonStyle())
                    .help("Stop the belt, put the pad to sleep, then quit")
            }
            .padding(.top, Theme.related)
        }
        // The first field would otherwise take focus on open and swallow
        // Space and the arrow keys.
        .onAppear {
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
    }

    // MARK: rows

    private var goalRow: some View {
        SettingRow(title: "Daily goal") {
            if viewModel.goalIsSteps {
                FieldPlate(width: 64) {
                    TextField("", value: $viewModel.dailyGoalSteps, format: .number)
                }
            } else {
                FieldPlate(width: 44) {
                    TextField("", value: $viewModel.dailyGoalMinutes, format: .number)
                }
            }
            ChipPicker(options: [(false, "min"), (true, "steps")], selection: $viewModel.goalIsSteps, compact: true)
        }
    }

    private var weightRow: some View {
        SettingRow(title: "Body weight") {
            FieldPlate(width: 56) {
                TextField("", text: $weightDraft)
                    .focused($weightFocused)
                    .onAppear(perform: syncWeight)
                    .onChange(of: viewModel.weightKg) { _, _ in if !weightFocused { syncWeight() } }
                    .onChange(of: viewModel.unitsImperial) { _, _ in syncWeight() }
                    .onChange(of: weightFocused) { _, focused in if !focused { commitWeight() } }
                    .onSubmit(commitWeight)
                    // An outside click tears the panel down without a focus
                    // change; keep what was typed.
                    .onDisappear { if weightFocused { commitWeight() } }
            }
            Text(viewModel.weightUnitLabel)
                .font(Theme.caption)
                .foregroundStyle(Theme.paper38)
                .frame(width: 14, alignment: .leading)
        }
    }

    private func wide(_ title: String) -> some View {
        Text(title)
            .font(Theme.bodyMedium)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .contentShape(.rect)
    }

    private var divider: some View {
        RowDivider().padding(.leading, Theme.inner)
    }

    private func cell<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, Theme.inner)
            .padding(.vertical, 7)
    }

    private func label(_ title: String, _ detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(Theme.body)
                .foregroundStyle(Theme.paper)
            if let detail {
                Text(detail)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.paper38)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func syncWeight() {
        let shown = viewModel.unitsImperial ? Z1Units.kgToLb(viewModel.weightKg) : viewModel.weightKg
        weightDraft = String(format: "%.1f", shown)
    }

    private func commitWeight() {
        let raw = weightDraft.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let value = Double(raw), value > 20, value < 400 else {
            syncWeight()
            return
        }
        // Untouched field: writing the rounded echo back nudged the stored
        // weight (lb round-trips especially) on every focus change.
        let shown = viewModel.unitsImperial ? Z1Units.kgToLb(viewModel.weightKg) : viewModel.weightKg
        if raw == String(format: "%.1f", shown) { return }
        viewModel.weightKg = viewModel.unitsImperial ? Z1Units.lbToKg(value) : value
        syncWeight()
    }
}
