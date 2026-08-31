import Foundation

/// Where the local update feed lives. The menu-bar app serves this folder on
/// 127.0.0.1:8741 while it is running.
public enum ReleaseDist {
    public static let port = 8741
    public static let feedName = "latest.json"

    public static func supportURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Z1 WalkingPad/updates", isDirectory: true)
    }

    public static func repoURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("z1-walkingpad/macos/release/dist", isDirectory: true)
    }

    public static func candidateDirectories() -> [URL] {
        [repoURL(), supportURL()]
    }

    public static func feed(in directory: URL) -> UpdateFeed? {
        let url = directory.appendingPathComponent(feedName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(UpdateFeed.self, from: data)
    }

    /// Prefer the folder whose `latest.json` is the newest build.
    public static func bestRoot(among directories: [URL] = candidateDirectories()) -> URL? {
        let fm = FileManager.default
        var ranked: [(url: URL, version: String)] = []
        for dir in directories {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let version = feed(in: dir)?.version ?? ""
            ranked.append((dir, version))
        }
        guard !ranked.isEmpty else { return nil }
        return ranked.max { a, b in
            a.version.compare(b.version, options: .numeric) == .orderedAscending
        }?.url
    }
}
