import Foundation

// MARK: - ScrobbleProvider

/// Sending end of the scrobble pipeline. Implementations talk to a specific
/// service (Last.fm, ListenBrainz, …) and translate `PlayEvent` rows into
/// service-shaped requests.
///
/// Implementations must be **`Sendable`** and safe to call from any actor —
/// the queue worker calls `submit(_:)` from its own actor context.
///
/// Authentication state is owned by the provider implementation; the orchestrator
/// only consults `isAuthenticated()` and surfaces the connect/disconnect UI.
public protocol ScrobbleProvider: Sendable {
    /// Stable identifier (`"lastfm"`, `"listenbrainz"`). Used as the
    /// `provider_id` in `scrobble_submissions`.
    var id: String { get }

    /// Human-readable name for UI (`"Last.fm"`).
    var displayName: String { get }

    /// Submit a "now playing" notification for a track that just started.
    /// Implementations should throttle internally so a fast track-skipper
    /// doesn't spam the service. Failures are logged and not surfaced to
    /// the user (now-playing is best-effort).
    func nowPlaying(_ play: PlayEvent) async throws

    /// Submit a batch of completed plays for permanent recording.
    /// Last.fm accepts up to 50 in a single request.
    /// Returns one result per `play` in the same order.
    func submit(_ plays: [PlayEvent]) async throws -> [SubmissionResult]

    /// Mark a track as loved (or unloved).
    func love(track: TrackIdentity, loved: Bool) async throws

    /// Whether the provider has stored, valid-looking credentials.
    /// Does not perform a network round-trip.
    func isAuthenticated() async -> Bool
}
