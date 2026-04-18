import Foundation

/// Wraps a security-scoped bookmark `Data` and resolves it to a file URL.
///
/// Phase 3 (scanning) uses this extensively to reopen sandboxed file URLs
/// after an app restart.
///
/// **Contract:** `resolve()` returns a URL with an already-started security scope.
/// The caller **must** call `stopAccessingSecurityScopedResource()` on the URL
/// when they are finished, or the kernel will leak the scope token.
///
/// ```swift
/// let url = try bookmark.resolve()
/// defer { url.stopAccessingSecurityScopedResource() }
/// let data = try Data(contentsOf: url)
/// ```
public struct BookmarkBlob: Codable, Sendable {
    // MARK: - Properties

    /// The raw bookmark data produced by `URL.bookmarkData(options:)`.
    public let data: Data

    // MARK: - Init

    /// Wraps existing bookmark data.
    public init(data: Data) {
        self.data = data
    }

    /// Creates a bookmark from `url`.
    ///
    /// Requires the app sandbox entitlement `com.apple.security.files.bookmarks.app-scope`.
    public init(url: URL) throws {
        self.data = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    // MARK: - Resolution

    /// Resolves the bookmark and starts accessing the security scope.
    ///
    /// Throws `PersistenceError.bookmarkResolutionFailed` if resolution fails.
    /// The caller **must** stop the security scope when done:
    /// ```swift
    /// defer { url.stopAccessingSecurityScopedResource() }
    /// ```
    public func resolve() throws -> URL {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: self.data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard url.startAccessingSecurityScopedResource() else {
                throw PersistenceError.bookmarkResolutionFailed(
                    reason: "startAccessingSecurityScopedResource returned false"
                )
            }
            return url
        } catch let err as PersistenceError {
            throw err
        } catch {
            throw PersistenceError.bookmarkResolutionFailed(reason: error.localizedDescription)
        }
    }

    /// Whether the bookmark data has gone stale (the file was moved or renamed).
    public var isStale: Bool {
        var stale = false
        _ = try? URL(
            resolvingBookmarkData: self.data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return stale
    }
}
