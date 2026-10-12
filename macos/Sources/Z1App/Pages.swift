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

/// Only what changes how the app behaves day to day.
struct SettingsPage: View {
    @Bindable var model: TreadmillViewModel

    var body: some View {
        PageScaffold {
            Card(padding: 0) {
                VStack(spacing: 0) {
                    cell {
                        SettingRow(title: "Daily goal") {
                            FieldPlate(width: 52) {
                                TextField("Daily goal", value: $model.dailyGoalMinutes, format: .number)
                                    .labelsHidden()
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
                            label("Remind me on quiet days", "Weekdays 9 to 6, at most twice a day")
                        }
                        .toggleStyle(PillToggleStyle())
                    }
                    divider
                    cell {
                        Toggle(isOn: $model.launchAtLogin) { label("Start at login", model.loginItemMessage) }
                            .toggleStyle(PillToggleStyle())
                    }
                }
            }
        }
        // The goal field would otherwise take focus on open and swallow
        // Space and the arrow keys.
        .onAppear {
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
    }

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
