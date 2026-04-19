import Foundation

/// Outcome of comparing a file against its last-known DB record.
public enum ChangeStatus: Sendable {
    /// File has never been seen before.
    case new
    /// File modification time or size has changed.
    case modified
    /// File is identical to the stored record.
    case unchanged
}

/// Detects whether a file is new, modified, or unchanged based on
/// stored `mtime` and `fileSize` values.
///
/// Also produces a set of "removed" file URLs from a snapshot of known
/// paths that were not visited during the current walk.
public actor ChangeDetector {
    // MARK: - State

    /// Known-file snapshot: URL string → (mtime, size)
    private var known: [String: (mtime: Int64, size: Int64)] = [:]

    /// URLs seen during the current scan pass.
    private var visited: Set<String> = []

    // MARK: - Init

    public init() {}

    // MARK: - API

    /// Seeds the detector with the current DB state before a scan begins.
    public func seed(_ entries: [(url: String, mtime: Int64, size: Int64)]) {
        self.known = Dictionary(uniqueKeysWithValues: entries.map { ($0.url, ($0.mtime, $0.size)) })
        self.visited = []
    }

    /// Checks `url` against the seed and marks it visited.
    ///
    /// - Returns: `.new`, `.modified`, or `.unchanged`.
    public func check(url: URL, mtime: Int64, size: Int64) -> ChangeStatus {
        let key = url.absoluteString
        self.visited.insert(key)
        guard let record = known[key] else { return .new }
        if record.mtime != mtime || record.size != size { return .modified }
        return .unchanged
    }

    /// Returns URLs from the seed that were never visited — i.e., removed files.
    public func removedURLs() -> [String] {
        self.known.keys.filter { !self.visited.contains($0) }
    }
}
