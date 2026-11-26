import Foundation

/// Outcome of comparing a file against its last-known DB record.
public enum ChangeStatus: Sendable {
    /// File has never been seen before.
    case new
    /// File modification time or size has changed.
    case modified
    /// File is identical to the stored record.
    case unchanged
    /// File is identical to the stored record, but the row has never stored
    /// the file's tag map (`tracks.extended_tags` is NULL). A quick scan reads
    /// the tags once to fill it and changes nothing else (#735).
    case unchangedWithoutTagMap
}

/// Detects whether a file is new, modified, or unchanged based on
/// stored `mtime` and `fileSize` values.
///
/// Also produces a set of "removed" file URLs from a snapshot of known
/// paths that were not visited during the current walk.
public actor ChangeDetector {
    // MARK: - State

    /// Known-file snapshot, keyed by the NFC-normalised URL string.
    private var known: [String: KnownFile] = [:]

    /// URLs seen during the current scan pass.
    private var visited: Set<String> = []

    // MARK: - Init

    public init() {}

    // MARK: - API

    /// One file the database already knows, as `seed(_:)` takes it.
    public struct KnownFile: Sendable {
        /// The stored file URL string.
        public let url: String
        /// The stored modification time.
        public let mtime: Int64
        /// The stored size in bytes.
        public let size: Int64
        /// Whether the row holds the file's tag map (`extended_tags` is not NULL).
        public let hasTagMap: Bool

        public init(url: String, mtime: Int64, size: Int64, hasTagMap: Bool = true) {
            self.url = url
            self.mtime = mtime
            self.size = size
            self.hasTagMap = hasTagMap
        }
    }

    /// Seeds the detector with the current DB state before a scan begins.
    public func seed(_ entries: [KnownFile]) {
        // NFC-normalise stored URL strings — APFS may report decomposed UTF-8
        // for the same on-disk file, so without this two scans of a path with
        // accented characters could disagree.
        self.known = Dictionary(uniqueKeysWithValues: entries.map {
            ($0.url.precomposedStringWithCanonicalMapping, $0)
        })
        self.visited = []
    }

    /// Checks `url` against the seed and marks it visited.
    ///
    /// - Returns: `.new`, `.modified`, `.unchanged`, or
    ///   `.unchangedWithoutTagMap` for an unchanged file whose row has no tag map.
    public func check(url: URL, mtime: Int64, size: Int64) -> ChangeStatus {
        let key = url.absoluteString.precomposedStringWithCanonicalMapping
        self.visited.insert(key)
        guard let record = known[key] else { return .new }
        if record.mtime != mtime || record.size != size {
            return .modified
        }
        return record.hasTagMap ? .unchanged : .unchangedWithoutTagMap
    }

    /// Returns URLs from the seed that were never visited — i.e., removed files.
    public func removedURLs() -> [String] {
        self.known.keys.filter { !self.visited.contains($0) }
    }
}
