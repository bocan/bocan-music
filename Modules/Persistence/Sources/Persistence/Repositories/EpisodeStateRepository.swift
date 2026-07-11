import Foundation
import GRDB
import Observability

/// The sole writer of `podcast_episode_state`.
///
/// All writes are upserts on the composite primary key `(podcast_id, guid)`,
/// creating the row on first touch. Absence of a row means unplayed, position 0.
///
/// `savePosition` is called frequently (every ~5 s while playing) and must never
/// reset the `played` state if the user has already marked the episode complete.
public struct EpisodeStateRepository: Sendable {
    // MARK: - Properties

    private let database: Database
    private let log = AppLogger.make(.persistence)

    // MARK: - Init

    public init(database: Database) {
        self.database = database
    }

    // MARK: - Read

    /// Returns the state row for `(podcastID, guid)`, or `nil` if never started.
    public func fetch(podcastID: Int64, guid: String) async throws -> PodcastEpisodeState? {
        try await self.database.read { db in
            try PodcastEpisodeState.fetchOne(db, key: ["podcast_id": podcastID, "guid": guid])
        }
    }

    /// Returns all state rows for a podcast.
    public func fetchAll(podcastID: Int64) async throws -> [PodcastEpisodeState] {
        try await self.database.read { db in
            try PodcastEpisodeState
                .filter(Column("podcast_id") == podcastID)
                .fetchAll(db)
        }
    }

    /// Returns every state row whose `download_state` is one of `states`, across
    /// all podcasts. Used by the download manager to resume interrupted downloads
    /// on launch (`.downloading` / `.queued`) and to enumerate downloaded
    /// episodes for storage eviction (`.downloaded`). Returns `[]` for an empty
    /// `states` array.
    public func fetchByDownloadState(_ states: [EpisodeDownloadState]) async throws -> [PodcastEpisodeState] {
        guard !states.isEmpty else { return [] }
        let raws = states.map(\.rawValue)
        return try await self.database.read { db in
            try PodcastEpisodeState
                .filter(raws.contains(Column("download_state")))
                .fetchAll(db)
        }
    }

    // MARK: - Write

    /// Persists the current play position and flips `play_state` to `inProgress`,
    /// unless the episode is already `played` (a finished episode that the user
    /// scrubbed back into keeps its played state until explicitly marked unplayed).
    ///
    /// Creates the state row if it does not yet exist.
    public func savePosition(
        podcastID: Int64,
        guid: String,
        position: Double,
        now: Double
    ) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: """
                INSERT INTO podcast_episode_state
                    (podcast_id, guid, play_position, play_state, last_played_at)
                VALUES (?, ?, ?, 'inProgress', ?)
                ON CONFLICT(podcast_id, guid) DO UPDATE SET
                    play_position  = excluded.play_position,
                    last_played_at = excluded.last_played_at,
                    play_state     = CASE WHEN play_state = 'played' THEN 'played' ELSE 'inProgress' END
                """,
                arguments: [podcastID, guid, position, now]
            )
        }
    }

    /// Marks the episode fully played: resets `play_position` to 0, sets `play_state`
    /// to `played`, and records `completed_at`.
    public func markPlayed(podcastID: Int64, guid: String, now: Double) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: """
                INSERT INTO podcast_episode_state
                    (podcast_id, guid, play_position, play_state, last_played_at, completed_at)
                VALUES (?, ?, 0.0, 'played', ?, ?)
                ON CONFLICT(podcast_id, guid) DO UPDATE SET
                    play_position  = 0.0,
                    play_state     = 'played',
                    last_played_at = excluded.last_played_at,
                    completed_at   = excluded.completed_at
                """,
                arguments: [podcastID, guid, now, now]
            )
        }
        self.log.debug("episode.markPlayed", ["podcastID": podcastID, "guid": guid])
    }

    /// Resets the episode to unplayed: clears `play_position`, `play_state`, and `completed_at`.
    public func markUnplayed(podcastID: Int64, guid: String) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: """
                INSERT INTO podcast_episode_state
                    (podcast_id, guid, play_position, play_state, last_played_at, completed_at)
                VALUES (?, ?, 0.0, 'unplayed', NULL, NULL)
                ON CONFLICT(podcast_id, guid) DO UPDATE SET
                    play_position = 0.0,
                    play_state    = 'unplayed',
                    completed_at  = NULL
                """,
                arguments: [podcastID, guid]
            )
        }
        self.log.debug("episode.markUnplayed", ["podcastID": podcastID, "guid": guid])
    }

    /// Marks every episode for a podcast as played in a single transaction.
    public func markAllPlayed(podcastID: Int64, now: Double) async throws {
        let guids = try await self.database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT guid FROM podcast_episodes WHERE podcast_id = ?",
                arguments: [podcastID]
            )
        }
        guard !guids.isEmpty else { return }
        try await self.database.write { db in
            for guid in guids {
                try db.execute(
                    sql: """
                    INSERT INTO podcast_episode_state
                        (podcast_id, guid, play_position, play_state, last_played_at, completed_at)
                    VALUES (?, ?, 0.0, 'played', ?, ?)
                    ON CONFLICT(podcast_id, guid) DO UPDATE SET
                        play_position  = 0.0,
                        play_state     = 'played',
                        last_played_at = excluded.last_played_at,
                        completed_at   = excluded.completed_at
                    """,
                    arguments: [podcastID, guid, now, now]
                )
            }
        }
        self.log.debug("episode.markAllPlayed", ["podcastID": podcastID, "count": guids.count])
    }

    // MARK: - Unread counts

    /// SQL for the per-show unread count: an episode is unread when it has no
    /// state row OR its `play_state` is not `played` (so `unplayed` and
    /// `inProgress` both count). Shows with zero unread episodes are absent from
    /// the result, not reported as a zero entry.
    private static let unplayedCountsSQL = """
    SELECT e.podcast_id AS podcast_id, COUNT(*) AS cnt
    FROM podcast_episodes e
    LEFT JOIN podcast_episode_state s
        ON s.podcast_id = e.podcast_id AND s.guid = e.guid
    WHERE s.play_state IS NULL OR s.play_state != 'played'
    GROUP BY e.podcast_id
    """

    private static func decodeUnplayedCounts(_ db: GRDB.Database) throws -> [Int64: Int] {
        let rows = try Row.fetchAll(db, sql: Self.unplayedCountsSQL)
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (Int64, Int)? in
            guard let id: Int64 = row["podcast_id"], let cnt: Int = row["cnt"] else { return nil }
            return (id, cnt)
        })
    }

    /// Unread counts keyed by podcast ID. Unread = no state row or
    /// `play_state != 'played'`. Shows with zero unread are absent.
    public func unplayedCounts() async throws -> [Int64: Int] {
        try await self.database.read { db in try Self.decodeUnplayedCounts(db) }
    }

    /// Streams unread counts, emitting immediately and again on any change to
    /// `podcast_episodes` or `podcast_episode_state` (both tables are read by the
    /// query, so the observation tracks both). A mark-played write clears a show's
    /// entry automatically.
    public func observeUnplayedCounts() async -> AsyncThrowingStream<[Int64: Int], Error> {
        await self.database.observe { db in try Self.decodeUnplayedCounts(db) }
    }

    /// Updates the download state, path, and byte count.
    public func setDownloadState(
        podcastID: Int64,
        guid: String,
        state: EpisodeDownloadState,
        path: String?,
        bytes: Int64?,
        hash: String? = nil
    ) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: """
                INSERT INTO podcast_episode_state
                    (podcast_id, guid, play_position, play_state,
                     download_state, download_path, download_bytes, content_hash)
                VALUES (?, ?, 0.0, 'unplayed', ?, ?, ?, ?)
                ON CONFLICT(podcast_id, guid) DO UPDATE SET
                    download_state = excluded.download_state,
                    download_path  = excluded.download_path,
                    download_bytes = excluded.download_bytes,
                    content_hash   = excluded.content_hash
                """,
                arguments: [podcastID, guid, state.rawValue, path, bytes, hash]
            )
        }
    }

    // MARK: - Observation

    /// A stream that emits all state rows for a podcast immediately and again on every change.
    public func observe(podcastID: Int64) async -> AsyncThrowingStream<[PodcastEpisodeState], Error> {
        await self.database.observe { db in
            try PodcastEpisodeState
                .filter(Column("podcast_id") == podcastID)
                .fetchAll(db)
        }
    }
}
