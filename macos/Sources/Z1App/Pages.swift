import AppKit
import SwiftUI
import Z1Core

/// A secondary page: content that scrolls inside the fixed window if it has
/// to. Its title lives in the title line beside the traffic lights.
struct PageScaffold<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
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

/// Plain explanatory text in a page.
struct Note: View {
    var text: String
    var body: some View {
        Text(text)
            .font(Theme.caption)
            .foregroundStyle(Theme.faint)
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
                .foregroundStyle(Theme.ink)
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
            .foregroundStyle(Theme.dim)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - History

struct HistoryPage: View {
    let model: TreadmillViewModel

    var body: some View {
        let walks = model.recentWalks
        PageScaffold {
            AlmanacCard(model: model)
            if walks.isEmpty {
                Note(text: "No walks yet.")
                    .padding(.top, 4)
            } else {
                ForEach(groups(walks), id: \.day) { group in
                    GroupLabel(text: dayTitle(group.day))
                    Card(padding: 0) {
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
                    .foregroundStyle(Theme.ink)
                Text("\(walk.steps.formatted()) steps est. · \(Int(walk.caloriesKcal.rounded())) kcal est.")
                    .font(Theme.caption.monospacedDigit())
                    .foregroundStyle(Theme.dim)
            }
            Spacer(minLength: Theme.related)
            VStack(alignment: .trailing, spacing: 2) {
                Text(model.formatDuration(walk.activeDurationS))
                    .font(Theme.bodyMedium.monospacedDigit())
                    .foregroundStyle(Theme.ink)
                Text(model.formatDistance(walk.distanceM))
                    .font(Theme.caption.monospacedDigit())
                    .foregroundStyle(Theme.dim)
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

struct RecordsPage: View {
    let model: TreadmillViewModel

    var body: some View {
        let hs = model.highScores
        PageScaffold {
            if hs.totalWalks == 0 {
                Note(text: "No records yet.")
            } else {
                GroupLabel(text: "Best walk")
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        rows([
                            hs.longestWalk.map { ("Longest", model.formatDuration($0.activeDurationS), $0.startedAt) },
                            hs.farthestWalk.map { ("Farthest", model.formatDistance($0.distanceM), $0.startedAt) },
                            hs.mostStepsWalk.map { ("Most steps est.", $0.steps.formatted(), $0.startedAt) },
                        ])
                    }
                }
                GroupLabel(text: "Best day")
                Card(padding: 0) {
                    VStack(spacing: 0) {
                        rows([
                            hs.longestDayTime.map { ("Time", model.formatDuration($0.activeDurationS), $0.day) },
                            hs.mostDistanceDay.map { ("Distance", model.formatDistance($0.distanceM), $0.day) },
                            hs.mostStepsDay.map { ("Steps est.", $0.steps.formatted(), $0.day) },
                            hs.bestStreakDays > 1 ? ("Streak", "\(hs.bestStreakDays) days", nil) : nil,
                        ])
                    }
                }
                GroupLabel(text: "Badges")
                Card {
                    badges
                }
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
                    .foregroundStyle(Theme.dim)
                Spacer(minLength: Theme.related)
                if let date = item.2 {
                    Text(date, format: .dateTime.day().month(.abbreviated))
                        .font(Theme.caption)
                        .foregroundStyle(Theme.faint)
                }
                Text(item.1)
                    .font(Theme.bodyMedium.monospacedDigit())
                    .foregroundStyle(Theme.ink)
                    .frame(minWidth: 70, alignment: .trailing)
            }
            .padding(.horizontal, Theme.inner)
            .frame(height: 34)
        }
    }

    private var badges: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: Theme.inner), GridItem(.flexible(), spacing: Theme.inner)],
            spacing: Theme.inner
        ) {
            ForEach(model.achievements) { ach in
                VStack(alignment: .leading, spacing: 7) {
                    Text(ach.kind.title)
                        .font(Theme.captionMedium)
                        .foregroundStyle(ach.unlocked ? Theme.ink : Theme.dim)
                        .lineLimit(1)
                    TickLine(progress: ach.progress, count: 26)
                        .frame(height: 7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(ach.kind.description)
            }
        }
    }
}

// MARK: - Settings

struct SettingsPage: View {
    @Bindable var model: TreadmillViewModel
    @State private var weightDraft = ""
    @FocusState private var weightFocused: Bool

    var body: some View {
        PageScaffold {
            GroupLabel(text: "Walking")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    cell { goalRow }
                    divider
                    cell {
                        SettingRow(title: "Speed per − / +") {
                            ChipPicker(options: [(0.1, "0.1"), (0.2, "0.2"), (0.5, "0.5")], selection: $model.speedStep, compact: true)
                        }
                    }
                    divider
                    cell {
                        SettingRow(title: "Units") {
                            ChipPicker(options: [(false, "Metric"), (true, "Imperial")], selection: $model.unitsImperial, compact: true)
                        }
                    }
                    divider
                    cell { weightRow }
                    divider
                    cell {
                        Toggle(isOn: $model.useHealthWeight) { label("Weight from Apple Health") }
                            .toggleStyle(PillToggleStyle())
                    }
                }
            }

            GroupLabel(text: "Notifications")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    cell {
                        Toggle(isOn: $model.notificationsEnabled) { label("When a walk is recorded") }
                            .toggleStyle(PillToggleStyle())
                    }
                    divider
                    cell {
                        Toggle(isOn: $model.remindersEnabled) { label("Remind me on quiet days") }
                            .toggleStyle(PillToggleStyle())
                    }
                    divider
                    cell {
                        SettingRow(title: "Quiet for") {
                            ChipPicker(options: [(2, "2h"), (3, "3h"), (4, "4h")], selection: $model.reminderGapHours, compact: true)
                                .disabled(!model.remindersEnabled)
                                .opacity(model.remindersEnabled ? 1 : 0.4)
                        }
                    }
                }
            }

            GroupLabel(text: "Steps")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    cell {
                        SettingRow(title: "Stride") {
                            Text(model.strideLabel)
                                .font(Theme.body.monospacedDigit())
                                .foregroundStyle(Theme.dim)
                        }
                    }
                    divider
                    cell {
                        HStack(spacing: Theme.related) {
                            Toggle(isOn: $model.persistStats) { label("Count across pad restarts") }
                                .toggleStyle(PillToggleStyle())
                            Button("Clear") { model.clearStatsTapped() }
                                .buttonStyle(SecondaryButtonStyle())
                                .disabled(!model.persistStats)
                        }
                    }
                }
            }

            GroupLabel(text: "App")
            Card(padding: 0) {
                VStack(spacing: 0) {
                    cell {
                        Toggle(isOn: $model.globalShortcutEnabled) {
                            label("\(GlobalHotKey.display) starts and stops")
                        }
                        .toggleStyle(PillToggleStyle())
                    }
                    divider
                    cell {
                        Toggle(isOn: $model.launchAtLogin) { label("Start at login", model.loginItemMessage) }
                            .toggleStyle(PillToggleStyle())
                    }
                    divider
                    cell {
                        SettingRow(title: model.live.deviceName ?? "Pad") {
                            Button(model.isConnected ? "Disconnect" : "Connect") { model.connectTapped() }
                                .buttonStyle(SecondaryButtonStyle())
                                .disabled(model.busy || model.isConnecting)
                        }
                    }
                }
            }

            HStack(spacing: Theme.related) {
                Button { model.quit() } label: { wide("Quit") }
                    .buttonStyle(PrimaryButtonStyle())
                    .help("Quit and leave the belt exactly as it is")
                Button { model.stopBeltAndQuit() } label: { wide("Stop pad and quit") }
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
            if model.goalIsSteps {
                FieldPlate(width: 64) {
                    TextField("", value: $model.dailyGoalSteps, format: .number)
                }
            } else {
                FieldPlate(width: 44) {
                    TextField("", value: $model.dailyGoalMinutes, format: .number)
                }
            }
            ChipPicker(options: [(false, "min"), (true, "steps")], selection: $model.goalIsSteps, compact: true)
        }
    }

    private var weightRow: some View {
        SettingRow(title: "Body weight") {
            FieldPlate(width: 56) {
                TextField("", text: $weightDraft)
                    .focused($weightFocused)
                    .onAppear(perform: syncWeight)
                    .onChange(of: model.weightKg) { _, _ in if !weightFocused { syncWeight() } }
                    .onChange(of: model.unitsImperial) { _, _ in syncWeight() }
                    .onChange(of: weightFocused) { _, focused in if !focused { commitWeight() } }
                    .onSubmit(commitWeight)
                    // Closing the window tears the page down without a focus
                    // change; keep what was typed.
                    .onDisappear { if weightFocused { commitWeight() } }
            }
            Text(model.weightUnitLabel)
                .font(Theme.caption)
                .foregroundStyle(Theme.faint)
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
                .foregroundStyle(Theme.ink)
            if let detail {
                Text(detail)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func syncWeight() {
        let shown = model.unitsImperial ? Z1Units.kgToLb(model.weightKg) : model.weightKg
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
        let shown = model.unitsImperial ? Z1Units.kgToLb(model.weightKg) : model.weightKg
        if raw == String(format: "%.1f", shown) { return }
        model.weightKg = model.unitsImperial ? Z1Units.lbToKg(value) : value
        syncWeight()
    }
}
