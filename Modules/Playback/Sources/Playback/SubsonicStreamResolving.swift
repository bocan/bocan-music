import Foundation

/// Resolves a `.subsonic` `PlayableSource` to a local file URL the
/// `AudioEngine` can decode. The concrete implementation lives in the app
/// target so the `Playback` module does not have to depend on `Subsonic`.
public protocol SubsonicStreamResolving: Sendable {
    /// Returns a local file URL that has been buffered far enough to start
    /// playback. May block while bytes arrive; honours `Task` cancellation.
    func localFileURL(serverID: UUID, songID: String) async throws -> URL

    /// Fire-and-forget pre-cache of the next queue item. Respects the
    /// server's `precacheNext` preference; silently no-ops if disabled or
    /// the server is unknown. Errors are swallowed.
    func precache(serverID: UUID, songID: String) async
}
