import Foundation
import Observability

/// Resolves and accesses security-scoped bookmarks.
public enum SecurityScope {
    /// Resolves `bookmark` to a URL, starts accessing its security scope,
    /// calls `body`, then stops access — even if `body` throws.
    ///
    /// - Parameters:
    ///   - bookmark: The security-scoped bookmark data to resolve.
    ///   - onStaleBookmark: Optional callback invoked (before `body`) when macOS flags
    ///     the bookmark as stale but still resolvable. Receives the resolved URL so the
    ///     caller can create a fresh bookmark and persist it. Errors thrown here are
    ///     logged but do not abort the main operation.
    ///   - body: Work to perform with the accessed URL.
    /// - Throws: ``LibraryError/bookmarkStale(_:)`` if the bookmark cannot be resolved.
    public static func withAccess<T>(
        _ bookmark: Data,
        onStaleBookmark: (@Sendable (URL) async -> Void)? = nil,
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
            await onStaleBookmark?(url)
        }

        return try await body(url)
    }
}
