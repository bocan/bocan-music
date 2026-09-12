/// Runs `body`, returning `nil` and logging the reason when it throws.
///
/// This is the recover-and-log shape from the `try?` audit, for a read whose
/// caller already has a sensible fallback. The caller keeps its `?? fallback`
/// exactly as written, and the reason the fallback was needed reaches the log
/// instead of being dropped on the floor:
///
/// ```swift
/// let counts = await logged("albums.trackCounts.failed", log) {
///     try await repository.fetchTrackCounts()
/// } ?? [:]
/// ```
///
/// It lives here because `Observability` owns the logger, and it is a free
/// function so that callers on an actor do not drag the work back onto that
/// actor: a method on a `@MainActor` view model would serialise reads the
/// caller deliberately runs in parallel. It also infers the read's type, so
/// call sites need no type annotation, which matters where a bare type name is
/// ambiguous between two imported modules.
///
/// Use it only where the caller genuinely recovers. A failed user action still
/// has to reach the user, and a value that will be written to the database or
/// sent on the wire must never come from a swallowed error. Where the recovery
/// needs more than one statement, write the `do`/`catch` out in full instead.
///
/// See `docs/audits/try-optional-audit.md` and #459.
public func logged<T: Sendable>(
    _ event: String,
    _ log: AppLogger,
    context: [String: any Sendable] = [:],
    _ body: @Sendable () async throws -> T
) async -> T? {
    do {
        return try await body()
    } catch {
        var fields: [String: Any] = context
        fields["error"] = String(reflecting: error)
        log.warning(event, fields)
        return nil
    }
}
