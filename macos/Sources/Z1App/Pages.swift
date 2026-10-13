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
        // Overlay scrollers, shown while scrolling: the macOS default.
        .scrollIndicators(.automatic)
        .scrollBounceBehavior(.basedOnSize)
    }
}

// MARK: - Intro

/// Shown once. Three lines, one button.
struct IntroPage: View {
    var globalShortcutAvailable = true
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
                line(globalShortcutAvailable
                     ? "\(GlobalHotKey.display) starts and stops from anywhere."
                     : "Global shortcut unavailable. Use Space in this window to start and stop.")
            }
            Spacer(minLength: 0)
            PrimaryButton(title: "Continue", height: 44, action: onContinue)
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

/// One week of goal bars. Nothing else: the app keeps time and distance, not
/// a stats collection.
struct HistoryPage: View {
    let model: TreadmillViewModel

    var body: some View {
        PageScaffold {
            WeekCard(model: model)
        }
    }
}

// MARK: - Settings

/// Only what changes how the app behaves day to day, and which build this is.
struct SettingsPage: View {
    @Bindable var model: TreadmillViewModel

    private static let buildLine = BuildInfo().line

    var body: some View {
        VStack(spacing: 0) {
            settings
            Text(Self.buildLine)
                .font(Theme.caption)
                .foregroundStyle(Theme.faint)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.top, Theme.related)
                .textSelection(.enabled)
                .accessibilityLabel("Build")
                .accessibilityValue(Self.buildLine)
        }
        // The goal field would otherwise take focus on open and swallow
        // Space and the arrow keys.
        .onAppear {
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
    }

    private var settings: some View {
        PageScaffold {
            Card(padding: 0) {
                VStack(spacing: 0) {
                    cell {
                        SettingRow(title: "Daily goal") {
                            FieldPlate(width: 52) {
                                TextField("Daily goal", value: $model.dailyGoalMinutes, format: .number)
                                    .labelsHidden()
                                    // The visible title is a sibling, not a label; say what
                                    // the number is and its unit.
                                    .accessibilityLabel("Daily goal in minutes")
                            }
                            Text("min")
                                .font(Theme.caption)
                                .foregroundStyle(Theme.dim)
                        }
                    }
                    divider
                    cell {
                        SettingRow(title: "Units") {
                            ChipPicker(options: [(false, "Metric"), (true, "Imperial")], selection: $model.unitsImperial, compact: true)
                        }
                    }
                    divider
                    cell {
                        Toggle(isOn: $model.remindersEnabled) {
                            label("Remind me on quiet days", model.reminderSchedule.summary)
                        }
                        .toggleStyle(PillToggleStyle())
                    }
                    if model.remindersEnabled {
                        divider
                        cell { reminderDays }
                        divider
                        cell { reminderHours }
                        divider
                        cell {
                            SettingRow(title: "At most") {
                                ChipPicker(
                                    options: [(1, "1"), (2, "2"), (3, "3")],
                                    selection: $model.reminderSchedule.perDay, compact: true
                                )
                                .accessibilityElement(children: .contain)
                                .accessibilityLabel("Reminders per day")
                                Text("a day")
                                    .font(Theme.caption)
                                    .foregroundStyle(Theme.dim)
                            }
                        }
                    }
                    divider
                    cell {
                        Toggle(isOn: $model.launchAtLogin) { label("Start at login", model.loginItemMessage) }
                            .toggleStyle(PillToggleStyle())
                    }
                }
            }
        }
    }

    /// Seven toggle chips, Monday first. The last chosen day cannot be switched
    /// off: a reminder schedule with no days would be silently dead.
    private var reminderDays: some View {
        let days: [(day: Int, letter: String, name: String)] = [
            (2, "M", "Monday"), (3, "T", "Tuesday"), (4, "W", "Wednesday"), (5, "T", "Thursday"),
            (6, "F", "Friday"), (7, "S", "Saturday"), (1, "S", "Sunday"),
        ]
        return SettingRow(title: "On") {
            HStack(spacing: 2) {
                ForEach(days, id: \.day) { entry in
                    let chosen = model.reminderSchedule.days.contains(entry.day)
                    Button {
                        var next = model.reminderSchedule.days
                        if chosen { if next.count > 1 { next.remove(entry.day) } } else { next.insert(entry.day) }
                        model.reminderSchedule.days = next
                    } label: {
                        Text(entry.letter)
                            .font(Theme.captionMedium)
                            .foregroundStyle(chosen ? Theme.ink : Theme.dim)
                            .frame(width: 22, height: 22)
                            .background {
                                if chosen { Capsule().fill(Theme.selection) }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(entry.name)
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
        }
    }

    private var reminderHours: some View {
        SettingRow(title: "Between") {
            Picker("From", selection: fromHour) {
                ForEach(0..<24, id: \.self) { Text(Self.hourName($0)).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityLabel("Remind from")
            Text("to")
                .font(Theme.caption)
                .foregroundStyle(Theme.dim)
            Picker("Until", selection: $model.reminderSchedule.untilHour) {
                ForEach(1...24, id: \.self) { Text(Self.hourName($0 % 24)).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityLabel("Remind until")
        }
    }

    /// Moving From through Until would leave an empty window; the schedule's
    /// initialiser nudges Until an hour past From, and this goes through it.
    private var fromHour: Binding<Int> {
        Binding(
            get: { model.reminderSchedule.fromHour },
            set: { hour in
                let current = model.reminderSchedule
                model.reminderSchedule = WalkReminderSchedule(
                    days: current.days, fromHour: hour, untilHour: current.untilHour, perDay: current.perDay
                )
            }
        )
    }

    private static func hourName(_ hour: Int) -> String { String(format: "%d:00", hour) }

    private var divider: some View {
        RowDivider().padding(.leading, Theme.inner)
    }

    private func cell<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, Theme.inner)
            .padding(.vertical, 8)
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
}
