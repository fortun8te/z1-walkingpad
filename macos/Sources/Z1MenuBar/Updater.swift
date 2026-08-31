import AppKit
import CryptoKit
import Foundation
import Z1Core

enum UpdatePhase: Equatable {
    case idle
    case checking
    case available(UpdateFeed)
    case downloading
    case installing
    case failed(String)
}

/// Checks the release feed, downloads a zip, verifies it, then hands off to
/// `apply-update.sh` so the running process can quit and the new binary open.
@MainActor
final class AppUpdater: ObservableObject {
    static let defaultFeedURL = "http://127.0.0.1:8741/latest.json"
    static let feedKey = "z1.updateFeedURL"

    @Published private(set) var phase: UpdatePhase = .idle

    private var lastCheck: Date?
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 120
        session = URLSession(configuration: config)
    }

    var feedURLString: String {
        let stored = UserDefaults.standard.string(forKey: Self.feedKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? Self.defaultFeedURL : stored
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    var currentShortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var buttonTitle: String {
        switch phase {
        case .idle, .checking: return "Check for update"
        case .available: return "Update available"
        case .downloading: return "Downloading…"
        case .installing: return "Installing…"
        case .failed: return "Update failed — retry"
        }
    }

    var availableNotes: String? {
        if case .available(let feed) = phase { return feed.notes }
        return nil
    }

    var isBusy: Bool {
        switch phase {
        case .downloading, .installing: return true
        default: return false
        }
    }

    func check(force: Bool = false) async {
        if !force, let lastCheck, Date().timeIntervalSince(lastCheck) < 10 * 60 {
            return
        }
        if isBusy { return }
        phase = .checking
        guard let url = URL(string: feedURLString) else {
            phase = .failed("Bad feed URL")
            return
        }
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                phase = .failed("Feed HTTP \(http.statusCode)")
                return
            }
            let feed = try JSONDecoder().decode(UpdateFeed.self, from: data)
            lastCheck = Date()
            if feed.packageURL == nil {
                phase = .failed("Feed has no package URL")
            } else if feed.isNewer(than: currentVersion) {
                phase = .available(feed)
            } else {
                phase = .idle
            }
        } catch {
            // No server running is the normal idle machine, not an error chip.
            phase = .idle
        }
    }

    /// Download, verify, stage, spawn the helper, then the caller must quit.
    func installAndPrepareRelaunch() async -> Bool {
        guard case .available(let feed) = phase else { return false }
        guard let package = feed.packageURL else {
            phase = .failed("Feed has no package URL")
            return false
        }
        phase = .downloading
        do {
            let (tmp, response) = try await session.download(from: package)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                phase = .failed("Package HTTP \(http.statusCode)")
                return false
            }
            let data = try Data(contentsOf: tmp)
            let digest = SHA256.hash(data: data)
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            let want = feed.sha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if want.isEmpty || hex != want {
                phase = .failed("Zip hash mismatch")
                return false
            }

            let stageRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("z1-update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: stageRoot, withIntermediateDirectories: true)
            let zip = stageRoot.appendingPathComponent("app.zip")
            try data.write(to: zip, options: .atomic)
            try run("/usr/bin/ditto", ["-x", "-k", zip.path, stageRoot.path])

            let staged = try findStagedApp(in: stageRoot)
            try validate(staged: staged, expectedVersion: feed.version)

            phase = .installing
            let helper = try materialiseHelper()
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [
                helper.path,
                staged.path,
                Bundle.main.bundlePath,
                String(ProcessInfo.processInfo.processIdentifier),
            ]
            try proc.run()
            return true
        } catch {
            phase = .failed(error.localizedDescription)
            return false
        }
    }

    private func findStagedApp(in root: URL) throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appendingPathComponent("Z1WalkingPad.app").path) {
            return root.appendingPathComponent("Z1WalkingPad.app")
        }
        let kids = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        if let hit = kids.first(where: { $0.lastPathComponent == "Z1WalkingPad.app" }) {
            return hit
        }
        throw NSError(
            domain: "z1.update",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Zip did not contain Z1WalkingPad.app"]
        )
    }

    private func validate(staged: URL, expectedVersion: String) throws {
        let info = staged.appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: info) as? [String: Any] else {
            throw NSError(
                domain: "z1.update",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Staged app has no Info.plist"]
            )
        }
        let bid = dict["CFBundleIdentifier"] as? String
        guard bid == "dev.z1walkingpad.menubar" else {
            throw NSError(
                domain: "z1.update",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Staged app is not Z1 WalkingPad"]
            )
        }
        let version = dict["CFBundleVersion"] as? String ?? ""
        guard version == expectedVersion else {
            throw NSError(
                domain: "z1.update",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Staged build \(version) ≠ feed \(expectedVersion)"]
            )
        }
    }

    private func materialiseHelper() throws -> URL {
        let bundled = Bundle.main.url(forResource: "apply-update", withExtension: "sh")
        let src = bundled ?? URL(fileURLWithPath: "/dev/null")
        guard bundled != nil, FileManager.default.isReadableFile(atPath: src.path) else {
            throw NSError(
                domain: "z1.update",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "apply-update.sh missing from the app bundle"]
            )
        }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("z1-apply-update.sh")
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: src, to: dest)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: dest.path
        )
        return dest
    }

    @discardableResult
    private func run(_ launchPath: String, _ arguments: [String]) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = arguments
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if proc.terminationStatus != 0 {
            throw NSError(
                domain: "z1.update",
                code: Int(proc.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: out.isEmpty ? "ditto failed" : out]
            )
        }
        return out
    }
}
