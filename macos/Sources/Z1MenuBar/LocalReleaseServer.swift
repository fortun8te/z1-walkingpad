import Darwin
import Foundation
import Z1Core

/// Serves the update folder on 127.0.0.1:8741.
///
/// In-process, on a background queue. `/usr/bin/python3` is an Xcode license
/// stub on this machine, and the old watchdog slept the main thread for 0.6s
/// every 20s while it waited for a server that never bound.
final class LocalReleaseServer: @unchecked Sendable {
    static let shared = LocalReleaseServer()

    private let queue = DispatchQueue(label: "z1.release-server")
    private let lock = NSLock()
    private var started = false
    private var listenFD: Int32 = -1

    func ensureRunning() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    func stopIfOwned() {
        lock.lock()
        let fd = listenFD
        listenFD = -1
        started = false
        lock.unlock()
        if fd >= 0 { close(fd) }
    }

    private func startOnQueue() {
        lock.lock()
        if started || listenFD >= 0 {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        guard let root = ReleaseDist.bestRoot() ?? Self.prepareEmptySupport() else {
            lock.lock()
            started = false
            lock.unlock()
            return
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else {
            lock.lock()
            started = false
            lock.unlock()
            return
        }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(ReleaseDist.port).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                bind(fd, sock, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            lock.lock()
            started = false
            lock.unlock()
            return
        }
        lock.lock()
        listenFD = fd
        lock.unlock()

        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { break }
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            DispatchQueue.global(qos: .utility).async {
                Self.serve(client: client, root: root)
                close(client)
            }
        }
        lock.lock()
        if listenFD == fd {
            listenFD = -1
            close(fd)
        }
        started = false
        lock.unlock()
    }

    private static func prepareEmptySupport() -> URL? {
        let url = ReleaseDist.supportURL()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func serve(client: Int32, root: URL) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let n = read(client, &buffer, buffer.count)
        guard n > 0 else { return }
        guard let text = String(bytes: buffer[..<n], encoding: .utf8),
              let line = text.split(separator: "\r\n", maxSplits: 1).first
        else { return }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return }
        let method = String(parts[0])
        guard method == "GET" || method == "HEAD" else {
            writeHTTP(client, status: 405, reason: "Method Not Allowed", type: "text/plain", body: Data())
            return
        }
        let raw = String(parts[1]).split(separator: "?").first.map(String.init) ?? "/"
        let relative = raw == "/" ? "" : String(raw.drop(while: { $0 == "/" }))
        let decoded = relative.removingPercentEncoding ?? relative
        if decoded.contains("..") || decoded.contains("\0") || decoded.hasPrefix("/") {
            writeHTTP(client, status: 403, reason: "Forbidden", type: "text/plain", body: Data())
            return
        }
        let rootStd = root.standardizedFileURL
        let file = rootStd.appendingPathComponent(decoded).standardizedFileURL
        let rootPath = rootStd.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard file.path == rootPath || file.path.hasPrefix(prefix) else {
            writeHTTP(client, status: 403, reason: "Forbidden", type: "text/plain", body: Data())
            return
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue,
              let body = try? Data(contentsOf: file)
        else {
            writeHTTP(client, status: 404, reason: "Not Found", type: "text/plain", body: Data())
            return
        }
        let type: String
        switch file.pathExtension.lowercased() {
        case "json": type = "application/json"
        case "zip": type = "application/zip"
        default: type = "application/octet-stream"
        }
        writeHTTP(client, status: 200, reason: "OK", type: type, body: method == "HEAD" ? Data() : body, length: body.count)
    }

    private static func writeHTTP(
        _ fd: Int32,
        status: Int,
        reason: String,
        type: String,
        body: Data,
        length: Int? = nil
    ) {
        let header = """
        HTTP/1.1 \(status) \(reason)\r
        Content-Type: \(type)\r
        Content-Length: \(length ?? body.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """
        var bytes = Data(header.utf8)
        bytes.append(body)
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let n = write(fd, base.advanced(by: sent), raw.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
    }
}
