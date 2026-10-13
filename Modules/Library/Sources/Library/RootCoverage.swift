import Foundation
import Persistence

// MARK: - RootCoverage

/// Decides whether a stored track is inside a set of library roots.
///
/// A root is a folder or a single file. A track's `file_url` is a
/// percent-encoded `file://` URL while a root is held as a plain path, and
/// either may name the same place through a symlink (`/var` and
/// `/private/var`), so a string prefix on the stored values is not enough
/// (#643). Each path is compared both as given and with symlinks resolved; a
/// path that cannot be resolved (an unplugged volume) is compared as given.
struct RootCoverage: Sendable {
    private let rootPaths: Set<String>

    /// - Parameter paths: Root paths, in any mix of raw and resolved forms.
    init(paths: [String]) {
        var all = Set<String>()
        for path in paths {
            all.insert(Self.trimmed(path))
            if let canonical = Self.canonicalPath(path) {
                all.insert(Self.trimmed(canonical))
            }
        }
        self.rootPaths = all
    }

    /// Where a stored track sits relative to the roots.
    enum Position: Sendable {
        /// One of the roots, or inside one.
        case inside
        /// A local file that no root holds.
        case outside
        /// Not a local file: no root can hold it and no root removal may touch it.
        case notLocal
    }

    /// Where `fileURL` (a stored `tracks.file_url`) sits relative to the roots.
    func position(ofFileURL fileURL: String) -> Position {
        guard let url = URL(string: fileURL), url.isFileURL else { return .notLocal }
        // The path as stored matches in the common case; only then pay for a
        // `realpath` call per track.
        if self.holds(Self.trimmed(url.path)) {
            return .inside
        }
        if let canonical = Self.canonicalPath(url.path), self.holds(Self.trimmed(canonical)) {
            return .inside
        }
        return .outside
    }

    private func holds(_ path: String) -> Bool {
        self.rootPaths.contains(path)
            || self.rootPaths.contains { LibraryRoot.directory($0, contains: path) }
    }

    /// The ids in `fileURLs` (track id to `file_url`) at `position`, ascending.
    func trackIDs(in fileURLs: [Int64: String], at position: Position) -> [Int64] {
        fileURLs.compactMap { id, fileURL in
            self.position(ofFileURL: fileURL) == position ? id : nil
        }
        .sorted()
    }

    /// `path` without a trailing slash, so a folder compares equal however it
    /// was spelled. The filesystem root stays `/`.
    private static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// `path` with symlinks resolved by `realpath(3)`, or `nil` when neither
    /// it nor its folder exists. Same reasoning as
    /// `ScanCoordinator.canonicalPath`. A deleted file in a folder that is
    /// still there resolves through the folder, so a deleted single-file root
    /// and its track still compare equal (#646).
    static func canonicalPath(_ path: String) -> String? {
        if let resolved = self.realPath(path) {
            return resolved
        }
        let url = URL(fileURLWithPath: path)
        guard url.pathComponents.count > 1,
              let folder = self.realPath(url.deletingLastPathComponent().path) else { return nil }
        return URL(fileURLWithPath: folder).appendingPathComponent(url.lastPathComponent).path
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
