import GRDB

/// A pending or submitted Last.fm / ListenBrainz scrobble.
public struct ScrobbleQueueItem: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    // MARK: - Table

    /// The database table name.
    public static let databaseTableName = "scrobble_queue"

    // MARK: - Properties

    /// Auto-incremented row identifier; `nil` before first insertion.
    public var id: Int64?

    /// The track that was played.
    public var trackID: Int64?

    /// Unix timestamp when playback started.
    public var playedAt: Int64

    /// Seconds of audio actually played (for ≥50% scrobble heuristic).
    public var durationPlayed: Double?

    /// Whether the scrobble has been submitted to the remote service.
    public var submitted: Bool

    /// Number of submission attempts (for back-off logic).
    public var submissionAttempts: Int

    // MARK: - Init

    // swiftlint:disable function_default_parameter_at_end
    /// Memberwise initialiser.
    public init(
        id: Int64? = nil,
        trackID: Int64? = nil,
        playedAt: Int64,
        durationPlayed: Double? = nil,
        submitted: Bool = false,
        submissionAttempts: Int = 0
    ) {
        self.id = id
        self.trackID = trackID
        self.playedAt = playedAt
        self.durationPlayed = durationPlayed
        self.submitted = submitted
        self.submissionAttempts = submissionAttempts
    }

    // swiftlint:enable function_default_parameter_at_end

    // MARK: - GRDB

    /// Captures the auto-incremented row ID after insertion.
    public mutating func didInsert(_ inserted: InsertionSuccess) {
        self.id = inserted.rowID
    }

    // MARK: - CodingKeys

    private enum CodingKeys: String, CodingKey {
        case id
        case trackID = "track_id"
        case playedAt = "played_at"
        case durationPlayed = "duration_played"
        case submitted
        case submissionAttempts = "submission_attempts"
    }
}
