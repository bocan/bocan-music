import Foundation

/// Resolves a `.jellyfin` `PlayableSource` to a local file URL the
/// `AudioEngine` can decode (ADR-097). The concrete implementation lives in
/// the App target, so `Playback` never depends on `Jellyfin`. It mirrors
/// `SubsonicStreamResolving`.
public protocol JellyfinStreamResolving: Sendable {
    /// Returns a local file URL once the stream cache has the whole file.
    /// May wait while bytes arrive; honours `Task` cancellation.
    func localFileURL(serverID: UUID, itemID: String) async throws -> URL

    /// Fire-and-forget pre-cache of the next queue item. Respects the
    /// server's `precacheNext` preference; does nothing if it is off or the
    /// server is unknown. Failures are logged, not thrown.
    func precache(serverID: UUID, itemID: String) async
}
