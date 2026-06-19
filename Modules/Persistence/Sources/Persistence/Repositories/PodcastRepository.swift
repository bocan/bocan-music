import Foundation
import GRDB
import Observability

/// Read/write access to the `podcasts` table.
///
/// `upsertByFeedURL` is the canonical write path during subscribe/refresh: it preserves
/// user-owned fields (`id`, `addedAt`, `subscribed`, `autoDownload`, `sortIndex`) while
/// updating all feed-derived content columns.
public struct PodcastRepository: Sendable {
    // MARK: - Properties

    private let database: Database
    private let log = AppLogger.make(.persistence)

    // MARK: - Init

    public init(database: Database) {
        self.database = database
    }

    // MARK: - Write

    /// Inserts a new podcast row. The `podcast.id` is set on return.
    @discardableResult
    public func insert(_ podcast: Podcast) async throws -> Int64 {
        let id: Int64 = try await self.database.write { db in
            var record = podcast
            try record.insert(db)
            return record.id ?? 0
        }
        self.log.debug("podcast.insert", ["id": id, "feedURL": podcast.feedURL])
        return id
    }

    /// Replaces an existing podcast row (all columns, including user-owned ones).
    /// Prefer `upsertByFeedURL` for feed-refresh paths.
    public func update(_ podcast: Podcast) async throws {
        try await self.database.write { db in
            try podcast.update(db)
        }
        self.log.debug("podcast.update", ["id": podcast.id ?? -1])
    }

    /// Inserts or updates keyed on `feed_url`.
    ///
    /// When the feed already exists the following fields are preserved from the existing
    /// row and are NOT replaced with the incoming values:
    /// `id`, `addedAt`, `subscribed`, `autoDownload`, `sortIndex`.
    /// All other columns (title, author, artwork, etag, etc.) are updated from the feed.
    ///
    /// Returns the rowid of the inserted or updated row.
    @discardableResult
    public func upsertByFeedURL(_ podcast: Podcast) async throws -> Int64 {
        let feedURL = podcast.feedURL
        let id: Int64 = try await self.database.write { db in
            if let existing = try Podcast.filter(Column("feed_url") == feedURL).fetchOne(db) {
                var updated = podcast
                updated.id = existing.id
                updated.addedAt = existing.addedAt
                updated.subscribed = existing.subscribed
                updated.autoDownload = existing.autoDownload
                updated.sortIndex = existing.sortIndex
                try updated.update(db)
                return existing.id ?? 0
            } else {
                var record = podcast
                try record.insert(db)
                return record.id ?? 0
            }
        }
        self.log.debug("podcast.upsertByFeedURL", ["id": id, "feedURL": feedURL])
        return id
    }

    /// Deletes a podcast row. Cascades to `podcast_episodes` and `podcast_episode_state`.
    public func delete(id: Int64) async throws {
        try await self.database.write { db in
            try db.execute(sql: "DELETE FROM podcasts WHERE id = ?", arguments: [id])
        }
        self.log.info("podcast.delete", ["id": id])
    }

    /// Updates only the `sort_index` column for a podcast.
    public func setSortIndex(id: Int64, sortIndex: Int) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: "UPDATE podcasts SET sort_index = ? WHERE id = ?",
                arguments: [sortIndex, id]
            )
        }
    }

    // MARK: - Read

    /// Fetches a podcast by primary key. Throws `PersistenceError.notFound` when absent.
    public func fetch(id: Int64) async throws -> Podcast {
        let record = try await self.database.read { db in
            try Podcast.fetchOne(db, key: id)
        }
        guard let record else {
            throw PersistenceError.notFound(entity: "Podcast", id: id)
        }
        return record
    }

    /// Fetches a podcast by its canonical `feed_url`, or `nil` if not subscribed.
    public func fetchByFeedURL(_ feedURL: String) async throws -> Podcast? {
        try await self.database.read { db in
            try Podcast.filter(Column("feed_url") == feedURL).fetchOne(db)
        }
    }

    /// Returns all subscribed podcasts ordered by `sort_index` then `title`.
    public func fetchAllSubscribed() async throws -> [Podcast] {
        try await self.database.read { db in
            try Podcast
                .filter(Column("subscribed") == true)
                .order(Column("sort_index"), Column("title"))
                .fetchAll(db)
        }
    }

    /// Returns podcasts whose `last_refreshed_at` is older than `interval` seconds ago,
    /// or NULL (never refreshed). Used by `FeedRefreshScheduler`.
    public func fetchStale(olderThan interval: TimeInterval, now: Double) async throws -> [Podcast] {
        let cutoff = now - interval
        return try await self.database.read { db in
            let condition = Column("subscribed") == true
                && (Column("last_refreshed_at") == nil || Column("last_refreshed_at") < cutoff)
            return try Podcast.filter(condition).fetchAll(db)
        }
    }

    // MARK: - Observation

    /// A stream that emits the full list of subscribed podcasts immediately and
    /// again on every insert, update, or delete to the `podcasts` table.
    public func observeSubscribed() async -> AsyncThrowingStream<[Podcast], Error> {
        await self.database.observe { db in
            try Podcast
                .filter(Column("subscribed") == true)
                .order(Column("sort_index"), Column("title"))
                .fetchAll(db)
        }
    }
}
