import Observability

/// Runs `fetch`, returning `nil` and logging the reason when it throws.
///
/// This is the class (b) shape from the `try?` audit, for a one-off read whose
/// caller already has a sensible fallback: the caller keeps its `?? fallback`
/// exactly as written, and the reason the fallback was needed reaches the log
/// instead of being dropped on the floor. See
/// `docs/audits/try-optional-audit.md` and #491.
///
/// It is a free function rather than a method on a view model for two reasons.
/// A `@MainActor` method would hop every `async let` child task straight back
/// to the main actor and serialise reads the callers deliberately run in
/// parallel. It also infers the fetched type, so call sites need no type
/// annotation: several of these reads return types whose bare names are
/// ambiguous in the `UI` module, where `Persistence` and the Subsonic client
/// both export a `Podcast` and a `PodcastEpisode`.
///
/// Use it only where the caller genuinely recovers. A failed user action still
/// has to reach the user, and a value that will be written to the database or
/// sent on the wire must never come from a swallowed error.
func recoveredRead<T: Sendable>(
    _ event: String,
    _ fetch: @Sendable () async throws -> T
) async -> T? {
    do {
        return try await fetch()
    } catch {
        AppLogger.make(.ui).warning(event, ["error": String(reflecting: error)])
        return nil
    }
}
