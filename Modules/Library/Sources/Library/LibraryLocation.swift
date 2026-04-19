import Foundation

/// Resolves well-known filesystem paths used by the Library module.
///
/// All paths live under `~/Library/Application Support/Bocan/`.
///
/// ```swift
/// // Cover art cache root
/// let cacheDir = LibraryLocation.coverArtCacheDirectory
///
/// // Bocan application support base
/// let base = LibraryLocation.applicationSupportDirectory
/// ```
public enum LibraryLocation: Sendable {
    // MARK: - Public directories

    /// `~/Library/Application Support/Bocan/` — created on first access.
    public static var applicationSupportDirectory: URL {
        bocanSupportDirectory()
    }

    /// `~/Library/Application Support/Bocan/CoverArt/` — created on first access.
    public static var coverArtCacheDirectory: URL {
        let dir = bocanSupportDirectory().appendingPathComponent("CoverArt", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return dir
    }

    // MARK: - Bookmark helpers

    /// Creates a security-scoped, app-scoped bookmark for `url`.
    ///
    /// - Throws: If the bookmark cannot be created (e.g. the URL is inaccessible).
    public static func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Resolves `bookmark` back to a URL and reports whether the bookmark is stale.
    ///
    /// - Returns: `(url, isStale)` — callers should refresh stale bookmarks.
    /// - Throws: If the bookmark data is corrupt or the underlying file is gone.
    public static func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return (url, stale)
    }

    // MARK: - Private

    private static func bocanSupportDirectory() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")

        let dir = base.appendingPathComponent("Bocan", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return dir
    }
}
