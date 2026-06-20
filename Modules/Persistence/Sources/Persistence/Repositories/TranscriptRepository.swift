import Foundation
import GRDB
import Observability

/// The sole writer of `podcast_episode_transcript`: a cache-first upsert and the
/// 30-day cleanup of transcripts whose episode is long-played.
public struct TranscriptRepository: Sendable {
    // MARK: - Properties

    private let database: Database
    private let log = AppLogger.make(.persistence)

    // MARK: - Init

    public init(database: Database) {
        self.database = database
    }

    // MARK: - Read

    /// Returns the cached transcript for `(podcastID, guid)`, or `nil` on a miss.
    public func fetch(podcastID: Int64, guid: String) async throws -> PodcastTranscript? {
        try await self.database.read { db in
            try PodcastTranscript.fetchOne(db, key: ["podcast_id": podcastID, "guid": guid])
        }
    }

    // MARK: - Write

    /// Inserts or replaces the cached transcript on the composite primary key.
    public func upsert(_ transcript: PodcastTranscript) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: """
                INSERT INTO podcast_episode_transcript
                    (podcast_id, guid, content, format, language, source_url, fetched_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(podcast_id, guid) DO UPDATE SET
                    content    = excluded.content,
                    format     = excluded.format,
                    language   = excluded.language,
                    source_url = excluded.source_url,
                    fetched_at = excluded.fetched_at
                """,
                arguments: [
                    transcript.podcastID,
                    transcript.guid,
                    transcript.content,
                    transcript.format.rawValue,
                    transcript.language,
                    transcript.sourceURL,
                    transcript.fetchedAt,
                ]
            )
        }
    }

    /// Deletes cached transcripts whose episode is `played` and whose clock
    /// (`completed_at` else `last_played_at`) is at or before `cutoff`. Transcripts
    /// with no state row, an `unplayed` / `inProgress` state, or no clock timestamp
    /// are kept. Returns the number of rows deleted. Pass `cutoff` in (do not read
    /// the clock inside the repo) so tests are deterministic.
    @discardableResult
    public func deletePlayedOlderThan(cutoff: Double) async throws -> Int {
        let deleted = try await self.database.write { db in
            try db.execute(
                sql: """
                DELETE FROM podcast_episode_transcript
                WHERE (podcast_id, guid) IN (
                    SELECT t.podcast_id, t.guid
                    FROM podcast_episode_transcript t
                    JOIN podcast_episode_state s
                      ON s.podcast_id = t.podcast_id AND s.guid = t.guid
                    WHERE s.play_state = 'played'
                      AND COALESCE(s.completed_at, s.last_played_at) IS NOT NULL
                      AND COALESCE(s.completed_at, s.last_played_at) <= ?
                )
                """,
                arguments: [cutoff]
            )
            return db.changesCount
        }
        if deleted > 0 {
            self.log.debug("transcript.cleanup", ["deleted": deleted])
        }
        return deleted
    }
}
