import Foundation

// MARK: - Row types

/// The value types the scrobble queue repository returns.
public extension ScrobbleQueueRepository {
    struct PendingRow: Sendable, Hashable {
        public let queueID: Int64
        public let trackID: Int64
        public let playedAt: Date
        public let durationPlayed: TimeInterval
        public let attempts: Int
        public let nextAttemptAt: Date?

        public let title: String
        public let artist: String
        public let albumArtist: String?
        public let album: String?
        public let duration: TimeInterval
        public let mbid: String?

        /// Set for Subsonic-sourced plays. The pair `(serverID, songID)` tells
        /// the Subsonic provider which server endpoint to hit. Both nil for
        /// local plays.
        public let subsonicServerID: UUID?
        public let subsonicSongID: String?
    }

    struct Stats: Sendable, Equatable {
        public let pending: Int
        public let dead: Int
        public let submittedToday: Int
    }

    // MARK: - SubmissionStatus

    /// Per-provider submission state mirroring the `scrobble_submissions.status` column.
    enum SubmissionStatus: String, Sendable, Hashable, CaseIterable {
        case pending
        case retry
        case sent
        /// The provider accepted the scrobble but persisting the clean
        /// success failed; recorded as a distinct terminal state so the row
        /// is never re-submitted (would be a double scrobble) yet the
        /// unconfirmed delivery stays visible. (#292)
        case sentUnconfirmed = "sent_unconfirmed"
        case failed
        case ignored

        /// Human-readable label shown in the UI.
        public var displayLabel: String {
            switch self {
            case .pending:
                "Queued"

            case .retry:
                "Retrying"

            case .sent:
                "Sent"

            case .sentUnconfirmed:
                "Sent (unconfirmed)"

            case .failed:
                "Failed"

            case .ignored:
                "Ignored"
            }
        }

        /// `true` for terminal states (no more work expected).
        public var isTerminal: Bool {
            self == .sent || self == .sentUnconfirmed || self == .failed || self == .ignored
        }
    }

    // MARK: - RecentRow

    /// One row per scrobble-queue entry, carrying per-provider submission status.
    /// Used by `RecentScrobblesView` to display the last N scrobbles.
    struct RecentRow: Sendable, Hashable {
        public let queueID: Int64
        public let playedAt: Date
        public let title: String
        public let artist: String
        public let album: String?
        /// Submission status keyed by provider ID ("lastfm", "listenbrainz").
        public let statusByProvider: [String: SubmissionStatus]

        /// The "worst" aggregate status across all providers (most actionable first).
        public var aggregateStatus: SubmissionStatus {
            let statuses = self.statusByProvider.values
            if statuses.contains(.failed) {
                return .failed
            }
            if statuses.contains(.retry) {
                return .retry
            }
            if statuses.contains(.pending) {
                return .pending
            }
            if statuses.contains(.ignored) {
                return .ignored
            }
            if statuses.contains(.sentUnconfirmed) {
                return .sentUnconfirmed
            }
            return .sent
        }
    }
}

/// The name `RecentRow.SubmissionStatus`, kept for callers outside the module.
public extension ScrobbleQueueRepository.RecentRow {
    /// Per-provider submission state. The type lives one level up, on the
    /// repository.
    typealias SubmissionStatus = ScrobbleQueueRepository.SubmissionStatus
}
