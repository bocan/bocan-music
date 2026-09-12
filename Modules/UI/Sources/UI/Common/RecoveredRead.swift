import Observability

/// Runs `fetch`, returning `nil` and logging the reason when it throws.
///
/// A thin wrapper over `Observability.logged(_:_:context:_:)` that supplies
/// this module's logging category, so the many call sites in the UI sweep read
/// as one short line. Everything that makes the shape work, and the rules for
/// when it is the wrong shape, are documented on `logged` itself.
///
/// See `docs/audits/try-optional-audit.md`, class (b), and #491.
func recoveredRead<T: Sendable>(
    _ event: String,
    _ fetch: @Sendable () async throws -> T
) async -> T? {
    await logged(event, AppLogger.make(.ui), fetch)
}
