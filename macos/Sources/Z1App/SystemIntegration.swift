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
    enum State: Equatable {
        case unavailable, disabled, enabled, requiresApproval

        var isRegistered: Bool { self == .enabled || self == .requiresApproval }
        var message: String? {
            self == .requiresApproval
                ? "Waiting for approval in System Settings → General → Login Items" : nil
        }
    }

    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    static var state: State {
        guard isAvailable else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        default: return .disabled
        }
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
            return nil
        } catch {
            return error.localizedDescription
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
/// what `swift run Z1App` is), so everything is gated on having one.
@MainActor
final class Notifier {
    private(set) var authorized = false
    private var didRequest = false
    private var authorizationGeneration = 0
    private let isAvailable: () -> Bool
    private let authorizationStatus: () async -> UNAuthorizationStatus
    private let requestAuthorization: () async throws -> Bool
    private let submit: (UNNotificationRequest) async throws -> Void

    // The narrow dependencies let tests exercise denied and failed delivery
    // without touching the real notification center or requesting permission.
    init(
        isAvailable: @escaping () -> Bool = {
            Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
        },
        authorizationStatus: @escaping () async -> UNAuthorizationStatus = {
            await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        },
        requestAuthorization: @escaping () async throws -> Bool = {
            try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
        },
        submit: @escaping (UNNotificationRequest) async throws -> Void = {
            try await UNUserNotificationCenter.current().add($0)
        }
    ) {
        self.isAvailable = isAvailable
        self.authorizationStatus = authorizationStatus
        self.requestAuthorization = requestAuthorization
        self.submit = submit
    }

    func refreshAuthorization() async {
        authorizationGeneration += 1
        let generation = authorizationGeneration
        guard isAvailable() else { authorized = false; return }
        let status = await authorizationStatus()
        guard !Task.isCancelled, generation == authorizationGeneration else { return }
        authorized = status == .authorized || status == .provisional
    }

    func requestAuthorizationIfNeeded() async {
        guard isAvailable(), !didRequest else { await refreshAuthorization(); return }
        didRequest = true
        do { _ = try await requestAuthorization() }
        catch {
            didRequest = false // A transient failure must not block the next explicit enable.
            NSLog("Z1App: notification authorization failed: \(error.localizedDescription)")
        }
        await refreshAuthorization()
    }

    /// True means the system accepted this request, not that a person saw it.
    /// Refresh first because authorization can change in System Settings.
    func post(title: String, body: String, identifier: String) async -> Bool {
        await refreshAuthorization()
        guard authorized, !Task.isCancelled else { return false }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await submit(request)
            return true
        } catch {
            NSLog("Z1App: could not post notification: \(error.localizedDescription)")
            return false
        }
    }
}

/// Quit has a real deadline even when native teardown ignores cancellation.
/// The losing task may unwind later, but cannot resume the continuation twice.
@MainActor
final class BoundedShutdown {
    private var continuation: CheckedContinuation<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    static func run(
        timeout: Duration,
        operation: @escaping @Sendable () async -> Void,
        onTimeout: @escaping @MainActor () -> Void
    ) async {
        let race = BoundedShutdown()
        await withCheckedContinuation { continuation in
            race.continuation = continuation
            race.operationTask = Task {
                await operation()
                race.finish()
            }
            race.timeoutTask = Task {
                do { try await Task.sleep(for: timeout) }
                catch { return }
                guard race.continuation != nil else { return }
                onTimeout()
                race.finish()
            }
        }
    }

    private func finish() {
        guard let continuation else { return }
        self.continuation = nil
        operationTask?.cancel()
        timeoutTask?.cancel()
        operationTask = nil
        timeoutTask = nil
        continuation.resume()
    }
}
