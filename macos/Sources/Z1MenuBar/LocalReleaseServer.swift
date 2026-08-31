import Darwin
import Foundation
import Z1Core

/// Serves `macos/release/dist` (or the Application Support copy) on
/// 127.0.0.1:8741 for the whole time the menu-bar app is open.
final class LocalReleaseServer: @unchecked Sendable {
    static let shared = LocalReleaseServer()

    private let lock = NSLock()
    private var child: Process?
    private var owned = false
    private var watchdog: Timer?

    func ensureRunning() {
        lock.lock()
        defer { lock.unlock() }
        if isListening() {
            if child == nil { owned = false }
            startWatchdogLocked()
            return
        }
        guard let root = ReleaseDist.bestRoot() ?? prepareEmptySupport() else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        spawnLocked(root: root)
        startWatchdogLocked()
    }

    func stopIfOwned() {
        lock.lock()
        defer { lock.unlock() }
        watchdog?.invalidate()
        watchdog = nil
        guard owned else { return }
        child?.terminate()
        child = nil
        owned = false
    }

    private func prepareEmptySupport() -> URL? {
        let url = ReleaseDist.supportURL()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func spawnLocked(root: URL) {
        if let existing = child, existing.isRunning { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.currentDirectoryURL = root
        proc.arguments = ["-c", Self.python, String(ReleaseDist.port)]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.child = nil
            self.lock.unlock()
        }
        do {
            try proc.run()
            child = proc
            owned = true
            waitUntilListening(timeout: 0.6)
        } catch {
            child = nil
            owned = false
        }
    }

    private func startWatchdogLocked() {
        guard watchdog == nil else { return }
        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            self?.ensureRunning()
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func waitUntilListening(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isListening() { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    func isListening() -> Bool {
        Self.portIsOpen(ReleaseDist.port)
    }

    static func portIsOpen(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                connect(fd, sock, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    private static let python = """
    import sys
    from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
    class H(SimpleHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        def log_message(self, fmt, *args):
            pass
        def end_headers(self):
            self.send_header("Cache-Control", "no-store")
            super().end_headers()
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
    """
}
