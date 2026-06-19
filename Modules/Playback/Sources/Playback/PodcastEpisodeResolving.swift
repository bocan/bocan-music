import Foundation

/// Resolves a `.podcast` `PlayableSource` to a playable URL and bridges
/// per-episode playback state (resume position, write-back, mark-played).
///
/// The concrete implementation lives in the app target (over `PodcastService`)
/// so the `Playback` module never has to depend on `Podcasts`. This mirrors
/// `SubsonicStreamResolving` exactly in spirit: a `Sendable` protocol the App
/// injects into `QueuePlayer`.
public protocol PodcastEpisodeResolving: Sendable {
    /// Local downloaded file URL when present, else the remote enclosure URL.
    func audioURL(feedURL: URL, episodeGUID: String) async throws -> URL

    /// Seconds to resume from. Returns 0 when there is no saved position or the
    /// episode is effectively complete.
    func resumePosition(feedURL: URL, episodeGUID: String) async -> TimeInterval

    /// Persist the current position. Called on the periodic update tick while
    /// playing and on pause / stop / app-quit.
    func persistPosition(
        feedURL: URL,
        episodeGUID: String,
        position: TimeInterval,
        duration: TimeInterval
    ) async

    /// Mark the episode fully played and reset its resume position.
    func markPlayed(feedURL: URL, episodeGUID: String) async
}
