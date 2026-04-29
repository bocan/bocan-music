import Foundation

/// RAII wrapper around a security-scoped URL.
///
/// `init` calls `startAccessingSecurityScopedResource()`; `deinit` calls
/// `stopAccessingSecurityScopedResource()`.  This eliminates the bare-pair
/// pattern flagged in the Phase 3 audit (M3) and lets callers hold the scope
/// for the lifetime of a `let` binding without an explicit `defer`.
///
/// `URL` is `Sendable`; the class is `@unchecked Sendable` because the
/// underlying access counter is itself thread-safe and the wrapper has no
/// other mutable state.
final class RootScopeHandle: @unchecked Sendable {
    let url: URL

    init?(url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return nil }
        self.url = url
    }

    deinit {
        self.url.stopAccessingSecurityScopedResource()
    }
}
