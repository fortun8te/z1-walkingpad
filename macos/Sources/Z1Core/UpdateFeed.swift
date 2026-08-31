import Foundation

/// What the release server publishes as `latest.json`.
///
/// `version` is the build number (`CFBundleVersion`, YYYYMMDDHHMM). The app
/// treats a feed as an update when that string is numerically newer than the
/// running build. `url` is a zip of `Z1WalkingPad.app`; `sha256` is of the zip.
public struct UpdateFeed: Codable, Equatable, Sendable {
    public var version: String
    public var shortVersion: String?
    public var url: String
    public var sha256: String
    public var notes: String?

    public init(
        version: String,
        shortVersion: String? = nil,
        url: String,
        sha256: String,
        notes: String? = nil
    ) {
        self.version = version
        self.shortVersion = shortVersion
        self.url = url
        self.sha256 = sha256
        self.notes = notes
    }

    public func isNewer(than currentVersion: String) -> Bool {
        let feed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = currentVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !feed.isEmpty, !current.isEmpty, feed != current else { return false }
        return feed.compare(current, options: .numeric) == .orderedDescending
    }

    public var packageURL: URL? { URL(string: url) }
}

public enum UpdateFeedError: Error, Equatable {
    case badURL
    case badJSON
    case missingPackage
}
