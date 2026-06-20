import Foundation
import GRDB
import Observability

// MARK: - EpisodeRepository

/// Read/write access to the `podcast_episodes` table.
///
/// This repository owns only episode *content*. It never reads or writes
/// `podcast_episode_state`. The joined `EpisodeListItem` read model is assembled
/// here via a LEFT JOIN so the UI gets content + state in one observation.
public struct EpisodeRepository: Sendable {
    // MARK: - Properties

    private let database: Database
    private let log = AppLogger.make(.persistence)

    // MARK: - Init

    public init(database: Database) {
        self.database = database
    }

    // MARK: - Write

    /// Upserts an episode keyed on `(podcast_id, guid)`.
    ///
    /// On insert, all columns are written. On update, only content columns are replaced;
    /// `added_at` is preserved so the original discovery time is stable. The state table
    /// is never touched.
    ///
    /// Returns the rowid of the inserted or updated row.
    @discardableResult
    public func upsert(_ episode: PodcastEpisode) async throws -> Int64 {
        try await self.database.write { db in
            try Self.upsertOne(episode, in: db)
        }
    }

    /// Bulk-upserts a list of episodes in a single transaction. More efficient than
    /// calling `upsert` in a loop for large feed refreshes.
    public func upsertAll(_ episodes: [PodcastEpisode]) async throws {
        guard !episodes.isEmpty else { return }
        try await self.database.write { db in
            for episode in episodes {
                try Self.upsertOne(episode, in: db)
            }
        }
        self.log.debug("episodes.upsertAll", ["count": episodes.count, "podcastID": episodes.first?.podcastID ?? -1])
    }

    /// Deletes content rows for a podcast whose guid is NOT in `keepGUIDs`.
    ///
    /// State rows in `podcast_episode_state` are NOT deleted by this call; they are keyed
    /// to `podcasts.id` and cascade only when the whole show is deleted. This preserves
    /// listening history even for episodes that temporarily dropped out of the feed.
    public func pruneEpisodes(podcastID: Int64, keepGUIDs: Set<String>) async throws {
        guard !keepGUIDs.isEmpty else {
            // Avoid building a zero-element IN clause; delete all episodes for the show.
            try await self.database.write { db in
                try db.execute(
                    sql: "DELETE FROM podcast_episodes WHERE podcast_id = ?",
                    arguments: [podcastID]
                )
            }
            self.log.debug("episodes.pruneAll", ["podcastID": podcastID])
            return
        }
        // SQLite IN clause with a bound array via GRDB StatementArguments (Sendable).
        let sortedGUIDs = keepGUIDs.sorted()
        let placeholders = sortedGUIDs.map { _ in "?" }.joined(separator: ", ")
        let deleteSQL = "DELETE FROM podcast_episodes WHERE podcast_id = ? AND guid NOT IN (\(placeholders))"
        // Build StatementArguments (Sendable, concrete DatabaseValue) before the closure.
        let stmtArgs = StatementArguments([podcastID.databaseValue] + sortedGUIDs.map(\.databaseValue))
        try await self.database.write { db in
            try db.execute(sql: deleteSQL, arguments: stmtArgs)
        }
        self.log.debug("episodes.prune", ["podcastID": podcastID, "keeping": keepGUIDs.count])
    }

    // MARK: - Read

    /// Fetches an episode by primary key. Throws `PersistenceError.notFound` when absent.
    public func fetch(id: Int64) async throws -> PodcastEpisode {
        let record = try await self.database.read { db in
            try PodcastEpisode.fetchOne(db, key: id)
        }
        guard let record else {
            throw PersistenceError.notFound(entity: "PodcastEpisode", id: id)
        }
        return record
    }

    /// Fetches an episode by `(podcastID, guid)`, or `nil` if not found.
    public func fetchByGUID(podcastID: Int64, guid: String) async throws -> PodcastEpisode? {
        try await self.database.read { db in
            try PodcastEpisode
                .filter(Column("podcast_id") == podcastID && Column("guid") == guid)
                .fetchOne(db)
        }
    }

    /// Fetches all episodes for a podcast, newest first.
    public func fetchForPodcast(podcastID: Int64) async throws -> [PodcastEpisode] {
        try await self.database.read { db in
            try PodcastEpisode
                .filter(Column("podcast_id") == podcastID)
                .order(Column("published_at").desc)
                .fetchAll(db)
        }
    }

    // MARK: - Joined read model

    /// Fetches `EpisodeListItem` rows for a podcast in the requested `order`.
    ///
    /// Each item joins the episode content with its optional state row
    /// (LEFT JOIN). `item.state == nil` means unplayed, position 0.
    public func fetchListItems(
        podcastID: Int64,
        order: EpisodeSortOrder = .newest
    ) async throws -> [EpisodeListItem] {
        try await self.database.read { db in
            try Self.listItemRequest(podcastID: podcastID, order: order).fetchAll(db).map(\.item)
        }
    }

    /// A live stream of `EpisodeListItem` rows in the requested `order`, emitting
    /// immediately and again whenever either `podcast_episodes` or
    /// `podcast_episode_state` changes for this podcast. The observation tracks
    /// both tables via a single joined SQL query.
    public func observeListItems(
        podcastID: Int64,
        order: EpisodeSortOrder = .newest
    ) async -> AsyncThrowingStream<[EpisodeListItem], Error> {
        await self.database.observe { db in
            try Self.listItemRequest(podcastID: podcastID, order: order).fetchAll(db).map(\.item)
        }
    }

    /// Returns episode counts keyed by podcast ID, in a single GROUP BY query.
    public func fetchAllPodcastCounts() async throws -> [Int64: Int] {
        try await self.database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT podcast_id, COUNT(*) AS cnt FROM podcast_episodes GROUP BY podcast_id"
            )
            return Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (Int64, Int)? in
                guard let id: Int64 = row["podcast_id"], let cnt: Int = row["cnt"] else { return nil }
                return (id, cnt)
            })
        }
    }

    // MARK: - Private helpers

    @discardableResult
    private static func upsertOne(_ episode: PodcastEpisode, in db: GRDB.Database) throws -> Int64 {
        // RETURNING id works on both insert and update paths (SQLite 3.35+, macOS 12+).
        let id = try Int64.fetchOne(
            db,
            sql: """
            INSERT INTO podcast_episodes
                (podcast_id, guid, title, subtitle, description_html, audio_url,
                 audio_mime, audio_byte_length, duration, published_at, season,
                 episode_number, episode_type, artwork_url, artwork_path,
                 chapters_url, transcript_url, link, explicit, added_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(podcast_id, guid) DO UPDATE SET
                title             = excluded.title,
                subtitle          = excluded.subtitle,
                description_html  = excluded.description_html,
                audio_url         = excluded.audio_url,
                audio_mime        = excluded.audio_mime,
                audio_byte_length = excluded.audio_byte_length,
                duration          = excluded.duration,
                published_at      = excluded.published_at,
                season            = excluded.season,
                episode_number    = excluded.episode_number,
                episode_type      = excluded.episode_type,
                artwork_url       = excluded.artwork_url,
                artwork_path      = excluded.artwork_path,
                chapters_url      = excluded.chapters_url,
                transcript_url    = excluded.transcript_url,
                link              = excluded.link,
                explicit          = excluded.explicit
            RETURNING id
            """,
            arguments: [
                episode.podcastID, episode.guid, episode.title, episode.subtitle,
                episode.descriptionHTML, episode.audioURL, episode.audioMIME,
                episode.audioByteLength, episode.duration, episode.publishedAt,
                episode.season, episode.episodeNumber, episode.episodeType,
                episode.artworkURL, episode.artworkPath, episode.chaptersURL,
                episode.transcriptURL, episode.link, episode.explicit, episode.addedAt,
            ]
        )
        return id ?? 0
    }

    /// Builds the joined episode + state query. `direction` is a fixed keyword
    /// derived from the `EpisodeSortOrder` enum (never a user string), so there is
    /// no injection surface; the `id` tiebreaker keeps equal/NULL `published_at`
    /// rows deterministic.
    private static func joinedSQL(order: EpisodeSortOrder) -> String {
        let direction = order == .oldest ? "ASC" : "DESC"
        return """
        SELECT e.*,
               s.play_position  AS st_play_position,
               s.play_state     AS st_play_state,
               s.last_played_at AS st_last_played_at,
               s.completed_at   AS st_completed_at,
               s.download_state AS st_download_state,
               s.download_path  AS st_download_path,
               s.download_bytes AS st_download_bytes
        FROM podcast_episodes e
        LEFT JOIN podcast_episode_state s
            ON s.podcast_id = e.podcast_id AND s.guid = e.guid
        WHERE e.podcast_id = ?
        ORDER BY e.published_at \(direction), e.id \(direction)
        """
    }

    private static func listItemRequest(podcastID: Int64, order: EpisodeSortOrder) -> SQLRequest<EpisodeListRow> {
        SQLRequest<EpisodeListRow>(sql: self.joinedSQL(order: order), arguments: [podcastID])
    }
}

// MARK: - EpisodeSortOrder

/// Episode list ordering by publish date. The raw value matches the persisted
/// `episode_sort` override.
public enum EpisodeSortOrder: String, Sendable, CaseIterable {
    case newest
    case oldest
}

/// Episode-sort resolution for a show.
public extension Podcast {
    /// Effective episode order: an explicit `episodeSort` override wins, else it
    /// is derived from `showType` (serial -> oldest, otherwise newest).
    var resolvedEpisodeSort: EpisodeSortOrder {
        if let raw = episodeSort, let explicit = EpisodeSortOrder(rawValue: raw) {
            return explicit
        }
        return showType == "serial" ? .oldest : .newest
    }
}

// MARK: - EpisodeListRow (private decoder)

/// File-private decoder that maps a joined episode + state row into `EpisodeListItem`.
///
/// `e.*` columns are decoded directly into `PodcastEpisode` via its `FetchableRecord`
/// implementation (unknown `st_*` columns are ignored by the Codable decoder).
/// The `st_*` columns carry the optional state fields from the LEFT JOIN.
private struct EpisodeListRow: FetchableRecord {
    let item: EpisodeListItem

    init(row: Row) throws {
        let episode = try PodcastEpisode(row: row)

        // The LEFT JOIN leaves st_play_state NULL when no state row matches.
        let stPlayStateRaw: String? = row["st_play_state"]
        guard let rawState = stPlayStateRaw else {
            self.item = EpisodeListItem(episode: episode, state: nil)
            return
        }

        let playState = EpisodePlayState(rawValue: rawState) ?? .unplayed
        let playPosition: Double = row["st_play_position"] ?? 0
        let lastPlayedAt: Double? = row["st_last_played_at"]
        let completedAt: Double? = row["st_completed_at"]
        let downloadStateRaw: String = row["st_download_state"] ?? EpisodeDownloadState.none.rawValue
        let downloadState = EpisodeDownloadState(rawValue: downloadStateRaw) ?? .none
        let downloadPath: String? = row["st_download_path"]
        let downloadBytes: Int64? = row["st_download_bytes"]

        let state = PodcastEpisodeState(
            podcastID: episode.podcastID,
            guid: episode.guid,
            playPosition: playPosition,
            playState: playState,
            lastPlayedAt: lastPlayedAt,
            completedAt: completedAt,
            downloadState: downloadState,
            downloadPath: downloadPath,
            downloadBytes: downloadBytes
        )
        self.item = EpisodeListItem(episode: episode, state: state)
    }
}
