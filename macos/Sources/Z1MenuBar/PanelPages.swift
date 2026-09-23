import SwiftUI
import Z1Core

/// A page inside the fixed panel: a title, then content that scrolls if it
/// has to. The panel itself never changes size.
struct PageScaffold<Content: View>: View {
    var title: String
    var trailing: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(Z1Type.medium(17))
                    .foregroundStyle(Z1.ink)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(Z1Type.regular(11))
                        .foregroundStyle(Z1.dim)
                }
            }
            .frame(height: 24)
            ScrollView(.vertical) {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

struct SectionLabel: View {
    var text: String
    var body: some View {
        Text(text)
            .font(Z1Type.regular(10))
            .foregroundStyle(Z1.faint)
            .padding(.top, 4)
    }
}

// MARK: - Intro

/// Shown once. Three lines, one button.
struct IntroPage: View {
    var onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer(minLength: 0)
            Text("Walk.\nDon't think about it.")
                .font(Z1Type.light(26))
                .foregroundStyle(Z1.ink)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                line("Start, stop and set speed from here or the remote. The pad only takes speed while the belt moves.")
                line("One Bluetooth connection at a time: close the phone app first.")
                line("Walks stay on this Mac and reach Apple Health through the Shortcut.")
            }
            Spacer(minLength: 0)
            Button(action: onContinue) {
                Text("Continue")
                    .font(Z1Type.medium(13))
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .contentShape(.rect)
            }
            .buttonStyle(PanelButtonStyle(lit: true))
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 4)
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(Z1Type.regular(12))
            .foregroundStyle(Z1.dim)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - History

@MainActor
struct HistoryPage: View {
    @ObservedObject var viewModel: TreadmillViewModel

    var body: some View {
        PageScaffold(title: "History", trailing: "\(viewModel.recentWalks.count) recent") {
            if viewModel.recentWalks.isEmpty {
                Text("Nothing recorded yet. Walks of two minutes or more land here.")
                    .font(Z1Type.regular(12))
                    .foregroundStyle(Z1.dim)
            } else {
                VStack(spacing: 0) {
                    ForEach(viewModel.recentWalks) { walk in
                        row(walk)
                        Rectangle().fill(Z1.hairline).frame(height: 0.7)
                    }
                }
            }
        }
    }

    private func row(_ walk: WalkSession) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(walk.startedAt, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
                    .font(Z1Type.regular(11))
                    .foregroundStyle(Z1.dim)
                Spacer()
                Text(viewModel.formatDuration(walk.activeDurationS))
                    .font(Z1Type.medium(13))
                    .foregroundStyle(Z1.ink)
            }
            Text("\(viewModel.formatDistance(walk.distanceM))  ·  \(walk.steps.formatted()) steps est.  ·  \(Int(walk.caloriesKcal.rounded())) kcal est.")
                .font(Z1Type.regular(11))
                .foregroundStyle(Z1.ink.opacity(0.8))
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Records

@MainActor
struct RecordsPage: View {
    @ObservedObject var viewModel: TreadmillViewModel

    var body: some View {
        let hs = viewModel.highScores
        return PageScaffold(
            title: "Records",
            trailing: hs.totalWalks > 0 ? "\(hs.totalWalks) walks · \(viewModel.formatDistance(hs.totalDistanceM))" : nil
        ) {
            if hs.totalWalks == 0 {
                Text("No records yet. A walk of two minutes or more lands here.")
                    .font(Z1Type.regular(12))
                    .foregroundStyle(Z1.dim)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Best walk")
                    if let w = hs.longestWalk {
                        record("Longest", viewModel.formatDuration(w.activeDurationS), date: w.startedAt)
                    }
                    if let w = hs.farthestWalk {
                        record("Farthest", viewModel.formatDistance(w.distanceM), date: w.startedAt)
                    }
                    if let w = hs.mostStepsWalk {
                        record("Most steps", w.steps.formatted(), date: w.startedAt)
                    }
                    SectionLabel(text: "Best day")
                    if let d = hs.longestDayTime {
                        record("Time", viewModel.formatDuration(d.activeDurationS), date: d.day)
                    }
                    if let d = hs.mostDistanceDay {
                        record("Distance", viewModel.formatDistance(d.distanceM), date: d.day)
                    }
                    if let d = hs.mostStepsDay {
                        record("Steps", d.steps.formatted(), date: d.day)
                    }
                    if hs.bestStreakDays > 1 {
                        record("Streak", "\(hs.bestStreakDays) days", date: nil)
                    }
                    SectionLabel(text: "Badges  \(viewModel.achievements.filter(\.unlocked).count) of \(viewModel.achievements.count)")
                    badges
                }
            }
        }
    }

    private func record(_ label: String, _ value: String, date: Date?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(Z1Type.regular(12))
                .foregroundStyle(Z1.dim)
            Spacer()
            if let date {
                Text(date, format: .dateTime.day().month(.abbreviated))
                    .font(Z1Type.regular(10))
                    .foregroundStyle(Z1.faint)
            }
            Text(value)
                .font(Z1Type.medium(13))
                .foregroundStyle(Z1.ink)
                .frame(minWidth: 64, alignment: .trailing)
        }
    }

    private var badges: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
            ForEach(viewModel.achievements) { ach in
                VStack(alignment: .leading, spacing: 5) {
                    Text(ach.kind.title)
                        .font(Z1Type.medium(11))
                        .foregroundStyle(ach.unlocked ? Z1.ink : Z1.dim)
                        .lineLimit(1)
                    TickLine(progress: ach.progress, count: 24)
                        .frame(height: 6)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(ach.unlocked ? Z1.hairlineLit : Z1.hairline, lineWidth: 0.7)
                )
                .help(ach.kind.description)
            }
        }
    }
}

// MARK: - Settings

@MainActor
struct SettingsPage: View {
    @ObservedObject var viewModel: TreadmillViewModel
    @State private var weightDraft = ""
    @FocusState private var weightFocused: Bool

    var body: some View {
        PageScaffold(
            title: "Settings",
            trailing: "Build \(viewModel.updater.currentVersion)"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "You")
                you
                SectionLabel(text: "Goal and menu bar")
                goal
                SectionLabel(text: "App")
                app
                SectionLabel(text: "Steps")
                steps
                SectionLabel(text: "Leaving")
                HStack {
                    Text("Stop the belt, sleep the pad, quit")
                        .font(Z1Type.regular(12))
                        .foregroundStyle(Z1.dim)
                    Spacer()
                    Button("Quit & sleep") { viewModel.stopBeltAndQuit() }
                        .buttonStyle(HairlineButtonStyle())
                        .font(Z1Type.regular(11))
                }
            }
        }
    }

    private var you: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Units") {
                Picker("", selection: $viewModel.unitsImperial) {
                    Text("Metric").tag(false)
                    Text("Imperial").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 140)
            }
            row("Body weight") {
                TextField("", text: $weightDraft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(width: 58)
                    .multilineTextAlignment(.trailing)
                    .focused($weightFocused)
                    .onAppear(perform: syncWeight)
                    .onChange(of: viewModel.weightKg) { _, _ in if !weightFocused { syncWeight() } }
                    .onChange(of: viewModel.unitsImperial) { _, _ in syncWeight() }
                    .onChange(of: weightFocused) { _, focused in if !focused { commitWeight() } }
                    .onSubmit(commitWeight)
                    // An outside click tears the panel down without a
                    // focus change; keep what was typed.
                    .onDisappear { if weightFocused { commitWeight() } }
                Text(viewModel.weightUnitLabel)
                    .font(Z1Type.regular(11))
                    .foregroundStyle(Z1.faint)
                    .frame(width: 16, alignment: .leading)
            }
            check("Use latest Apple Health weight", $viewModel.useHealthWeight)
            if let stamp = viewModel.healthWeightStamp {
                note(stamp)
            }
            row("Speed per − / +") {
                Picker("", selection: $viewModel.speedStep) {
                    Text("0.1").tag(0.1)
                    Text("0.2").tag(0.2)
                    Text("0.5").tag(0.5)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 120)
            }
        }
    }

    private var goal: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Daily goal") {
                if viewModel.goalIsSteps {
                    TextField("", value: $viewModel.dailyGoalSteps, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(width: 62)
                        .multilineTextAlignment(.trailing)
                } else {
                    TextField("", value: $viewModel.dailyGoalMinutes, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(width: 44)
                        .multilineTextAlignment(.trailing)
                }
                Picker("", selection: $viewModel.goalIsSteps) {
                    Text("min").tag(false)
                    Text("steps").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 96)
            }
            row("Menu bar shows") {
                Picker("", selection: $viewModel.menuBarReadout) {
                    ForEach(MenuBarReadout.allCases) { readout in
                        Text(readout.label).tag(readout)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 140)
            }
            check("Show it when the belt is stopped", $viewModel.menuBarAlwaysVisible)
                .disabled(viewModel.menuBarReadout == .none)
        }
    }

    private var app: some View {
        VStack(alignment: .leading, spacing: 8) {
            check("Start at login", $viewModel.launchAtLogin)
            if let message = viewModel.loginItemMessage { note(message) }
            check("Show in Dock", $viewModel.showInDock)
            check("Install updates automatically", $viewModel.autoUpdate)
            check("Notify when a walk is recorded", $viewModel.notificationsEnabled)
            HStack {
                check("Remind me on quiet days", $viewModel.remindersEnabled)
                Spacer()
                Picker("", selection: $viewModel.reminderGapHours) {
                    Text("2h").tag(2)
                    Text("3h").tag(3)
                    Text("4h").tag(4)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 96)
                .disabled(!viewModel.remindersEnabled)
            }
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Stride") {
                Text(viewModel.strideLabel)
                    .font(Z1Type.regular(12))
                    .foregroundStyle(Z1.ink)
            }
            note("Steps come from belt distance and a speed-dependent stride. Belt distance is the exact number.")
            HStack {
                check("Keep counting across pad restarts", $viewModel.persistStats)
                Spacer()
                Button("Clear") { viewModel.clearStatsTapped() }
                    .buttonStyle(HairlineButtonStyle())
                    .font(Z1Type.regular(11))
                    .disabled(!viewModel.persistStats)
            }
        }
    }

    // MARK: pieces

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(Z1Type.regular(12))
                .foregroundStyle(Z1.dim)
            Spacer(minLength: 6)
            content()
        }
        .frame(minHeight: 22)
    }

    private func check(_ title: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            Text(title)
                .font(Z1Type.regular(12))
                .foregroundStyle(Z1.ink.opacity(0.85))
        }
        .toggleStyle(.checkbox)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Z1Type.regular(10))
            .foregroundStyle(Z1.faint)
            .fixedSize(horizontal: false, vertical: true)
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
