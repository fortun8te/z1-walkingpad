import SwiftUI
import Z1Core

/// Single-screen first-launch intro — TLDR, not 4 screens.
/// Says Z1 bla bla: what it is, how it works, what to expect.
/// Shown once, dismissed forever (UserDefaults z1.hasSeenIntro).
struct OnboardingView: View {
    var onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "figure.walk.motion")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Z1.ink)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Z1 WalkingPad")
                        .font(Z1Type.medium(22))
                        .foregroundStyle(Z1.ink)
                    Text("KingSmith Z1 · Bluetooth FTMS · macOS menu bar")
                        .font(Z1Type.regular(11))
                        .foregroundStyle(Z1.faint)
                }
                Spacer()
            }

            Text("Walk. Don't think about it.")
                .font(Z1Type.light(15))
                .foregroundStyle(Z1.ink.opacity(0.9))

            VStack(alignment: .leading, spacing: 9) {
                bullet("Controls", "Start / Stop, drag the dial or type 3.1, tap −/+ to nudge (0.1·0.2·0.5). The pad only takes speed changes while the belt moves.")
                bullet("Master", "The pad is the master. Remote, app, or pad timer — the numbers always show what the pad reports. Calories & steps survive reconnects (gap-credited).")
                bullet("Steps", "Auto-learns your stride at ≥3 km/h from stable 12-sec windows (needs 3 windows + 100 m). Or set your own stride in Settings for exact distance→steps.")
                bullet("Daily", "120 min or 8K steps goal, 1.6–6.4 km/h, imperial/metric synced to pad LEDs. Today's strip toggles Week/30 days; Records shows highscores & badges.")
                bullet("Staying connected", "One BLE connection only — quit phone app before Connect. Auto-reconnects on wake, holds idle sleep while belt moves, Exit sleeps pad.")
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Z1.hairline, lineWidth: 0.7))

            HStack(spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(Z1.faint).font(.system(size: 11))
                Text("Local + private: walks in ~/Library/Application Support/Z1 WalkingPad/sessions.json. No cloud by default. Export via agent-data.json or Health Shortcut.")
                    .font(Z1Type.regular(10))
                    .foregroundStyle(Z1.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: onContinue) {
                Text("Continue  →")
                    .font(Z1Type.medium(13))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Z1.ink)
            .background(Capsule().fill(Z1.live))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.7))
            .keyboardShortcut(.defaultAction)
        }
        .padding(18)
        .frame(width: 340)
        .background(Z1.canvas)
    }

    private func bullet(_ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("·").font(Z1Type.medium(13)).foregroundStyle(Z1.faint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Z1Type.medium(11)).foregroundStyle(Z1.ink)
                Text(body).font(Z1Type.regular(10)).foregroundStyle(Z1.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview {
    OnboardingView(onContinue: {})
        .background(Z1.canvas)
}
