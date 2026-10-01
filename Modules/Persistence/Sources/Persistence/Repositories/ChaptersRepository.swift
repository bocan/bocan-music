import Foundation
import GRDB

/// The sole writer of `podcast_episode_chapters`: the cache of fetched
/// Podcasting 2.0 chapters documents (#608).
///
/// Every read here returns only a *current* document: one whose `source_url`
/// still equals the episode's `chapters_url`. A feed that moves or drops its
/// chapters therefore stops the old document being used, with no delete.
public struct ChaptersRepository: Sendable {
    // MARK: - Properties

    private let database: Database

    // MARK: - Init

    public init(database: Database) {
        self.database = database
    }

    // MARK: - Read

    /// Returns the current cached document for `(podcastID, guid)`, or `nil`
    /// on a miss or when the episode's `chapters_url` has since changed.
    public func fetchCurrent(podcastID: Int64, guid: String) async throws -> PodcastChapters? {
        try await self.database.read { db in
            try PodcastChapters.fetchOne(
                db,
                sql: """
                SELECT c.*
                FROM podcast_episode_chapters c
                JOIN podcast_episodes e
                  ON e.podcast_id = c.podcast_id AND e.guid = c.guid
                WHERE c.podcast_id = ? AND c.guid = ? AND e.chapters_url = c.source_url
                """,
                arguments: [podcastID, guid]
            )
        }
    }

    /// The GUIDs of the episodes of `podcastID` that have a current cached
    /// document. One query per show, for the Phone Sync manifest.
    public func guidsWithCurrentChapters(podcastID: Int64) async throws -> Set<String> {
        try await self.database.read { db in
            try Set(String.fetchAll(
                db,
                sql: """
                SELECT c.guid
                FROM podcast_episode_chapters c
                JOIN podcast_episodes e
                  ON e.podcast_id = c.podcast_id AND e.guid = c.guid
                WHERE c.podcast_id = ? AND e.chapters_url = c.source_url
                """,
                arguments: [podcastID]
            ))
        }
    }

    // MARK: - Write

    /// Inserts or replaces the cached document on the composite primary key.
    ///
    /// A document identical to the stored one writes nothing, so the usual
    /// once-a-session re-fetch does not look like a library change to the
    /// Phone Sync generation observer.
    public func upsert(_ chapters: PodcastChapters) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: """
                INSERT INTO podcast_episode_chapters (podcast_id, guid, content, source_url)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(podcast_id, guid) DO UPDATE SET
                    content    = excluded.content,
                    source_url = excluded.source_url
                WHERE content != excluded.content OR source_url != excluded.source_url
                """,
                arguments: [chapters.podcastID, chapters.guid, chapters.content, chapters.sourceURL]
            )
        }
    }
}
