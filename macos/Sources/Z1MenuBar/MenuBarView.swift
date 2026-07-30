import SwiftUI
import Z1Core

struct MenuBarView: View {
    @ObservedObject var viewModel: TreadmillViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            connectionRow
            speedControl
            startStopButton
            statsGrid
            if let summary = viewModel.lastSummary {
                summaryLine(summary)
            }
            if let error = viewModel.status.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            settingsSection
            Divider()
            quitRow
        }
        .padding(14)
        .frame(width: 300)
    }

    // MARK: - connection

    private var connectionRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(viewModel.isConnected ? .green : .secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(viewModel.status.deviceName ?? "WalkingPad Z1")
                    .font(.headline)
                Text(phaseLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(viewModel.isConnected ? "Disconnect" : "Connect") {
                viewModel.connectTapped()
            }
            .disabled(viewModel.busy)
        }
    }

    private var phaseLabel: String {
        switch viewModel.status.phase {
        case .disconnected: "Not connected"
        case .scanning: "Scanning…"
        case .connecting: "Connecting…"
        case .ready: "Connected"
        case .error: "Connection failed"
        }
    }

    // MARK: - speed

    private var speedControl: some View {
        HStack {
            stepperButton(systemName: "minus", action: viewModel.speedDownTapped)
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(viewModel.displaySpeed, format: .number.precision(.fractionLength(1)))
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(viewModel.speedUnitLabel)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            stepperButton(systemName: "plus", action: viewModel.speedUpTapped)
        }
    }

    private func stepperButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title2.weight(.semibold))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.bordered)
        .disabled(!viewModel.status.beltRunning || viewModel.busy)
    }

    // MARK: - start/stop

    private var startStopButton: some View {
        Button(action: viewModel.startStopTapped) {
            Label(
                viewModel.status.beltRunning ? "Stop" : "Start",
                systemImage: viewModel.status.beltRunning ? "stop.fill" : "play.fill"
            )
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .tint(viewModel.status.beltRunning ? .red : .green)
        .disabled(!viewModel.isConnected || viewModel.busy)
    }

    // MARK: - stats

    private var statsGrid: some View {
        let s = viewModel.status
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            statCell(value: formatElapsed(s.elapsedS), label: "Elapsed", icon: "clock")
            statCell(value: viewModel.formatDistance(s.distanceM), label: "Distance", icon: "map")
            statCell(value: "\(s.steps)", label: "Steps", icon: "figure.walk")
            statCell(
                value: s.caloriesKcal.formatted(.number.precision(.fractionLength(1))),
                label: "kcal (est.)",
                icon: "flame"
            )
        }
    }

    private func statCell(value: String, label: String, icon: String) -> some View {
        VStack(spacing: 3) {
            Label(label, systemImage: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .medium))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.quaternary, in: .rect(cornerRadius: 8))
    }

    private func summaryLine(_ s: SessionSummary) -> some View {
        Text(
            "Last session: \(formatElapsed(s.durationS)) · \(viewModel.formatDistance(s.distanceM)) · "
                + "\(s.steps) steps · \(s.caloriesKcal.formatted(.number.precision(.fractionLength(1)))) kcal"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - settings

    private var settingsSection: some View {
        DisclosureGroup("Settings") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Units", selection: $viewModel.unitsImperial) {
                    Text("Imperial").tag(true)
                    Text("Metric").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                HStack {
                    Label("Body weight", systemImage: "scalemass")
                        .font(.callout)
                    Spacer()
                    TextField(
                        "weight",
                        value: viewModel.weightBinding,
                        format: .number.precision(.fractionLength(0...1))
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 64)
                    .multilineTextAlignment(.trailing)
                    Text(viewModel.weightUnitLabel)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Speed per −/+ tap")
                        .font(.callout)
                    Spacer()
                    Picker("Speed per −/+ tap", selection: $viewModel.speedStep) {
                        Text("0.1").tag(0.1)
                        Text("0.2").tag(0.2)
                        Text("0.5").tag(0.5)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 150)
                    Text(viewModel.speedUnitLabel)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)
        }
    }

    private var quitRow: some View {
        HStack {
            Spacer()
            Button("Quit Z1 WalkingPad") {
                viewModel.quit()
            }
            .keyboardShortcut("q")
        }
    }

    // MARK: - formatting

    private func formatElapsed(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
