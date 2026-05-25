import Foundation

// MARK: - SubsonicMetadataCaching

/// Lets per-server browse view-models render instantly from a persisted
/// snapshot before kicking off a live re-fetch. Implemented by the App
/// layer against `SubsonicServerRepository`; UI consumes the protocol so
/// the module stays decoupled from `Persistence`.
///
/// All methods are best-effort: failures should be swallowed by the
/// implementation, so cache misses look identical to "no cache yet".
public protocol SubsonicMetadataCaching: Sendable {
    /// Returns the cached payload for the given key, or `nil` on miss /
    /// staleness / decode failure.
    func loadCache(serverID: UUID, entityKind: String, entityID: String) async -> Data?

    /// Writes a fresh payload for the given key. Errors are swallowed.
    func saveCache(serverID: UUID, entityKind: String, entityID: String, payload: Data) async
}
