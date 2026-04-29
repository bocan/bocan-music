import Foundation

// MARK: - PlayEvent

/// Everything a scrobble provider could need from a single play.
///
/// Built by the scrobble service from a `scrobble_queue` row joined with the
/// underlying `tracks` row. Immutable once created so it can be safely passed
/// through actors and submitted concurrently to multiple providers.
public struct PlayEvent: Sendable, Codable, Hashable {
    /// `scrobble_queue.id` — the row this event was constructed from.
    public let queueID: Int64
    /// `tracks.id`.
    public let trackID: Int64
    public let artist: String
    public let albumArtist: String?
    public let album: String?
    public let title: String
    public let duration: TimeInterval
    /// MusicBrainz recording ID, if the track has one.
    public let mbid: String?
    /// UTC start-of-play timestamp. Last.fm rejects timestamps more than
    /// 14 days in the past or in the future.
    public let playedAt: Date

    public init(
        queueID: Int64,
        trackID: Int64,
        artist: String,
        albumArtist: String? = nil,
        album: String? = nil,
        title: String,
        duration: TimeInterval,
        mbid: String? = nil,
        playedAt: Date
    ) {
        self.queueID = queueID
        self.trackID = trackID
        self.artist = artist
        self.albumArtist = albumArtist
        self.album = album
        self.title = title
        self.duration = duration
        self.mbid = mbid
        self.playedAt = playedAt
    }
}

// MARK: - TrackIdentity

/// Minimal artist+title identity used for love/unlove. Matches what the providers expect.
public struct TrackIdentity: Sendable, Codable, Hashable {
    public let artist: String
    public let title: String
    public let mbid: String?

    public init(artist: String, title: String, mbid: String? = nil) {
        self.artist = artist
        self.title = title
        self.mbid = mbid
    }
}

// MARK: - SubmissionResult

/// The outcome of submitting a single `PlayEvent` to a provider.
public struct SubmissionResult: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case success
        case ignored(reason: String) // accepted but service skipped (e.g. duplicate)
        case retry(reason: String, after: TimeInterval?)
        case permanentFailure(reason: String)
    }

    public let queueID: Int64
    public let outcome: Outcome

    public init(queueID: Int64, outcome: Outcome) {
        self.queueID = queueID
        self.outcome = outcome
    }
}
