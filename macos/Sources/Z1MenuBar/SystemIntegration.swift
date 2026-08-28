import AppKit
import Foundation
import ServiceManagement
import UserNotifications

/// Start-at-login registration.
///
/// `SMAppService` needs a real, stably-located app bundle: registering from a
/// `swift run` build (or from a bundle still sitting in Downloads) fails, so
/// every call reports its outcome rather than failing silently.
@MainActor
enum LoginItem {
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static var isEnabled: Bool {
        isAvailable && SMAppService.mainApp.status == .enabled
    }

    /// Returns nil on success, or a human-readable reason it did not take.
    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        guard isAvailable else { return "Only available in the installed app" }
        do {
            let service = SMAppService.mainApp
            if enabled {
                guard service.status != .enabled else { return nil }
                try service.register()
            } else {
                guard service.status != .notRegistered else { return nil }
                try service.unregister()
            }
            if service.status == .requiresApproval {
                return "Waiting for approval in System Settings → General → Login Items"
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// True once macOS has the registration but the user has not approved it
    /// yet (System Settings → General → Login Items).
    static var needsApproval: Bool {
        isAvailable && SMAppService.mainApp.status == .requiresApproval
    }

    /// Raw status, recorded to defaults so a failed registration can be
    /// diagnosed without a debugger — ad-hoc signed builds and bundles outside
    /// /Applications both fail here, silently, in different ways.
    static var statusDescription: String {
        guard isAvailable else { return "unavailable (no app bundle)" }
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notRegistered: return "notRegistered"
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }
}

/// Keeps the Mac awake while the belt is moving.
///
/// A walk that outlives the idle-sleep timer used to be cut in half: the Mac
/// slept, BLE dropped, and the rest of the walk was never seen. This holds an
/// idle-sleep assertion for exactly as long as the belt runs.
///
/// It does not (and cannot) defeat closing the lid or an explicit Sleep.
@MainActor
final class SleepBlocker {
    private var token: NSObjectProtocol?

    var isHolding: Bool { token != nil }

    func setActive(_ active: Bool) {
        if active {
            guard token == nil else { return }
            token = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "WalkingPad session in progress"
            )
        } else {
            guard let token else { return }
            ProcessInfo.processInfo.endActivity(token)
            self.token = nil
        }
    }
}

/// Local notifications, best-effort.
///
/// `UNUserNotificationCenter` traps in a process with no app bundle (which is
/// what `swift run Z1MenuBar` is), so everything is gated on having one.
@MainActor
final class Notifier {
    private var authorized = false
    private var didRequest = false

    private var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    func requestAuthorizationIfNeeded() {
        guard isAvailable, !didRequest else { return }
        didRequest = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { NSLog("Z1MenuBar: notification authorization failed: \(error.localizedDescription)") }
            Task { @MainActor in self.authorized = granted }
        }
    }

    func post(title: String, body: String, identifier: String) {
        guard isAvailable, authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("Z1MenuBar: could not post notification: \(error.localizedDescription)") }
        }
    }
}

/// What rides in the menu bar next to the icon.
enum MenuBarReadout: String, CaseIterable, Identifiable, Sendable {
    case none
    case speed
    case elapsed
    case distance
    case steps
    case calories
    case todayTime
    case todaySteps

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "Icon only"
        case .speed: "Speed"
        case .elapsed: "Elapsed"
        case .distance: "Distance"
        case .steps: "Steps"
        case .calories: "Calories"
        case .todayTime: "Today's minutes"
        case .todaySteps: "Today's steps"
        }
    }
}
