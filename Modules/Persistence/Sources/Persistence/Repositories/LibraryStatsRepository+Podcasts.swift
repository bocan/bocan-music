import Foundation
import GRDB

// MARK: - LibraryPodcastReport

/// The podcast accounting for the Library Summary window (#373, ADR-077 slice 1):
/// what the backlog costs, which feeds died, what got downloaded but never
/// heard, and what listened-and-forgotten audio still holds disk. All
/// figures cover subscribed shows only. Structured data; prose (and the
/// footnoted estimates) belong to the UI layer.
public struct LibraryPodcastReport: Equatable, Sendable {
    /// A subscribed show whose feed has gone quiet.
    public struct DeadFeed: Equatable, Sendable, Identifiable {
        public let id: Int64
        public let title: String
        /// Unix timestamp of the newest episode: the last sign of life.
        public let lastPublishedAt: Double
    }

    /// A show with downloaded episodes nobody has started.
    public struct UnplayedDownloads: Equatable, Sendable, Identifiable {
        public let id: Int64
        public let title: String
        public let episodeCount: Int
        public let bytes: Int64
    }

    /// Subscribed shows, for the empty-state gate.
    public let subscribedShowCount: Int

    /// Seconds of unheard audio: unplayed episodes at full duration plus
    /// in-progress remainders.
    public let backlogSeconds: Double
    /// Estimated listening throughput in seconds per week, averaged over
    /// ``LibraryStatsRepository/podcastRateWindowWeeks``. An estimate: each
    /// episode's consumed time is attributed to its last touch.
    public let weeklyListeningSeconds: Double

    public let deadFeedCount: Int
    /// Longest-dead first, capped at ``LibraryHygieneReport/maxExamples``.
    public let deadFeeds: [DeadFeed]

    public let unplayedDownloadShowCount: Int
    public let unplayedDownloadEpisodeCount: Int
    public let unplayedDownloadBytes: Int64
    /// Largest hoard first, capped at ``LibraryHygieneReport/maxExamples``.
    public let unplayedDownloads: [UnplayedDownloads]

    /// Played more than 90 days ago and still on disk.
    public let reapableEpisodeCount: Int
    public let reapableBytes: Int64
}

// MARK: - Podcast accounting queries

/// The Podcasts tab detectors (#373, ADR-077 slice 1), split from the other
/// report slices so each file stays focused.
public extension LibraryStatsRepository {
    /// Days without a new episode before a subscribed feed counts as dead.
    static let podcastDeadFeedDays = 180
    /// Days after completion before a downloaded episode counts as reapable.
    static let podcastReapableAgeDays = 90
    /// Averaging window for the listening-rate estimate.
    static let podcastRateWindowWeeks = 26

    /// One reapable download's identity, for the pane's Reap Now action.
    struct ReapableEpisode: Equatable, Sendable {
        public let podcastID: Int64
        public let guid: String
    }

    /// The identity pairs behind ``LibraryPodcastReport/reapableEpisodeCount``
    /// (ADR-077 slice 3), so Reap Now can hand each row to the same download
    /// machinery the per-episode Remove Download action uses.
    func fetchReapableEpisodes() async throws -> [ReapableEpisode] {
        let cutoff = Date().timeIntervalSince1970 - Double(Self.podcastReapableAgeDays) * 86400
        return try await self.database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT state.podcast_id AS pid, state.guid AS guid
                FROM podcast_episode_state AS state
                JOIN podcasts ON podcasts.id = state.podcast_id
                WHERE state.play_state = 'played'
                  AND state.download_state = 'downloaded'
                  AND state.download_path IS NOT NULL
                  AND COALESCE(state.completed_at, state.last_played_at, 0) < ?
                  AND COALESCE(state.completed_at, state.last_played_at, 0) > 0
                """,
                arguments: [cutoff]
            )
            return rows.compactMap { row in
                guard let pid: Int64 = row["pid"], let guid: String = row["guid"] else { return nil }
                return ReapableEpisode(podcastID: pid, guid: guid)
            }
        }
    }

    /// Runs every podcast-accounting query in one read transaction.
    func fetchPodcastReport() async throws -> LibraryPodcastReport {
        let now = Date().timeIntervalSince1970
        let deadCutoff = now - Double(Self.podcastDeadFeedDays) * 86400
        let reapCutoff = now - Double(Self.podcastReapableAgeDays) * 86400
        let rateCutoff = now - Double(Self.podcastRateWindowWeeks) * 7 * 86400
        return try await self.database.read { db in
            let dead = try Self.deadFeeds(db, cutoff: deadCutoff)
            let unplayed = try Self.unplayedDownloads(db)
            let reapable = try Self.reapable(db, cutoff: reapCutoff)
            return try LibraryPodcastReport(
                subscribedShowCount: Self.subscribedShowCount(db),
                backlogSeconds: Self.backlogSeconds(db),
                weeklyListeningSeconds: Self.recentListeningSeconds(db, since: rateCutoff)
                    / Double(Self.podcastRateWindowWeeks),
                deadFeedCount: dead.total,
                deadFeeds: dead.examples,
                unplayedDownloadShowCount: unplayed.count,
                unplayedDownloadEpisodeCount: unplayed.reduce(0) { $0 + $1.episodeCount },
                unplayedDownloadBytes: unplayed.reduce(0) { $0 + $1.bytes },
                unplayedDownloads: Array(unplayed.prefix(LibraryHygieneReport.maxExamples)),
                reapableEpisodeCount: reapable.count,
                reapableBytes: reapable.bytes
            )
        }
    }
}

private extension LibraryStatsRepository {
    static func subscribedShowCount(_ db: GRDB.Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM podcasts") ?? 0
    }

    /// Unplayed episodes at full duration, in-progress at the remainder.
    /// Episodes with no state row are unplayed by definition.
    static func backlogSeconds(_ db: GRDB.Database) throws -> Double {
        try Double.fetchOne(db, sql: """
            SELECT COALESCE(SUM(
                CASE
                    WHEN state.play_state = 'played' THEN 0
                    WHEN state.play_state = 'inProgress'
                        THEN MAX(0, COALESCE(episodes.duration, 0) - COALESCE(state.play_position, 0))
                    ELSE COALESCE(episodes.duration, 0)
                END), 0)
            FROM podcast_episodes AS episodes
            JOIN podcasts ON podcasts.id = episodes.podcast_id
            LEFT JOIN podcast_episode_state AS state
                ON state.podcast_id = episodes.podcast_id AND state.guid = episodes.guid
        """) ?? 0
    }

    /// Consumed seconds whose last touch falls inside the rate window:
    /// played episodes at full duration, in-progress at their position.
    static func recentListeningSeconds(_ db: GRDB.Database, since cutoff: Double) throws -> Double {
        try Double.fetchOne(
            db,
            sql: """
            SELECT COALESCE(SUM(
                CASE WHEN state.play_state = 'played' THEN COALESCE(episodes.duration, 0)
                     ELSE COALESCE(state.play_position, 0) END), 0)
            FROM podcast_episode_state AS state
            JOIN podcasts ON podcasts.id = state.podcast_id
            JOIN podcast_episodes AS episodes
                ON episodes.podcast_id = state.podcast_id AND episodes.guid = state.guid
            WHERE state.play_state IN ('played', 'inProgress')
              AND COALESCE(state.completed_at, state.last_played_at) >= ?
            """,
            arguments: [cutoff]
        ) ?? 0
    }

    static func deadFeeds(
        _ db: GRDB.Database,
        cutoff: Double
    ) throws -> (total: Int, examples: [LibraryPodcastReport.DeadFeed]) {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT podcasts.id AS id,
                   podcasts.title AS title,
                   MAX(episodes.published_at) AS latest
            FROM podcasts
            JOIN podcast_episodes AS episodes ON episodes.podcast_id = podcasts.id
            GROUP BY podcasts.id
            HAVING latest IS NOT NULL AND latest < ?
            ORDER BY latest ASC
            """,
            arguments: [cutoff]
        )
        let examples: [LibraryPodcastReport.DeadFeed] = rows
            .prefix(LibraryHygieneReport.maxExamples)
            .compactMap { row in
                guard let id: Int64 = row["id"] else { return nil }
                return LibraryPodcastReport.DeadFeed(
                    id: id,
                    title: row["title"] ?? "",
                    lastPublishedAt: row["latest"] ?? 0
                )
            }
        return (rows.count, examples)
    }

    static func unplayedDownloads(_ db: GRDB.Database) throws -> [LibraryPodcastReport.UnplayedDownloads] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT podcasts.id AS id,
                   podcasts.title AS title,
                   COUNT(*) AS cnt,
                   COALESCE(SUM(state.download_bytes), 0) AS bytes
            FROM podcast_episode_state AS state
            JOIN podcasts ON podcasts.id = state.podcast_id
            WHERE state.download_state = 'downloaded' AND state.play_state = 'unplayed'
            GROUP BY podcasts.id
            ORDER BY bytes DESC, podcasts.title ASC
        """)
        return rows.compactMap { row in
            guard let id: Int64 = row["id"] else { return nil }
            return LibraryPodcastReport.UnplayedDownloads(
                id: id,
                title: row["title"] ?? "",
                episodeCount: row["cnt"] ?? 0,
                bytes: row["bytes"] ?? 0
            )
        }
    }

    static func reapable(_ db: GRDB.Database, cutoff: Double) throws -> (count: Int, bytes: Int64) {
        let row = try Row.fetchOne(
            db,
            sql: """
            SELECT COUNT(*) AS cnt, COALESCE(SUM(state.download_bytes), 0) AS bytes
            FROM podcast_episode_state AS state
            JOIN podcasts ON podcasts.id = state.podcast_id
            WHERE state.play_state = 'played'
              AND state.download_state = 'downloaded'
              AND state.download_path IS NOT NULL
              AND COALESCE(state.completed_at, state.last_played_at, 0) < ?
              AND COALESCE(state.completed_at, state.last_played_at, 0) > 0
            """,
            arguments: [cutoff]
        )
        return (row?["cnt"] ?? 0, row?["bytes"] ?? 0)
    }
}
