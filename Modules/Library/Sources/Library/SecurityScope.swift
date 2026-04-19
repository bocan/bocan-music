import Foundation
import Observability

/// Resolves and accesses security-scoped bookmarks.
public enum SecurityScope {
    /// Resolves `bookmark` to a URL, starts accessing its security scope,
    /// calls `body`, then stops access — even if `body` throws.
    ///
    /// - Throws: ``LibraryError/bookmarkStale(_:)`` if the bookmark cannot be resolved.
    public static func withAccess<T>(
        _ bookmark: Data,
        _ body: (URL) async throws -> T
    ) async throws -> T {
        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw LibraryError.bookmarkStale(URL(fileURLWithPath: "/"))
        }

        guard url.startAccessingSecurityScopedResource() else {
            throw LibraryError.bookmarkStale(url)
        }
        defer { url.stopAccessingSecurityScopedResource() }

        if isStale {
            AppLogger.make(.library).warning("security_scope.stale", ["url": url.path])
        }

        return try await body(url)
    }
}
