import Foundation
import GRDB

// MARK: - LibraryPodcastBehaviourReport

/// The podcast behaviour analytics (#373, ADR-077 slice 2): how shows actually
/// get listened to. Completion and abandonment, episode length creep, and
/// the publish-to-play gap. All figures cover subscribed shows only; the
/// first-listen timestamps are proxied (the schema stores last-played), and
/// the UI footnotes it.
public struct LibraryPodcastBehaviourReport: Equatable, Sendable {
    /// One show's finish-versus-abandon record.
    public struct ShowCompletion: Equatable, Sendable, Identifiable {
        public let id: Int64
        public let title: String
        /// Episodes played to completion.
        public let playedCount: Int
        /// Episodes started and stalled.
        public let inProgressCount: Int
        /// Mean stall position in seconds over abandoned episodes, when any.
        public let meanAbandonSeconds: Double?

        /// Played over started, 0...1.
        public var completionRate: Double {
            let started = self.playedCount + self.inProgressCount
            return started > 0 ? Double(self.playedCount) / Double(started) : 0
        }
    }

    /// One show's mean episode duration, first qualifying year against the
    /// latest, because nearly every successful podcast bloats.
    public struct ShowCreep: Equatable, Sendable, Identifiable {
        public let id: Int64
        public let title: String
        public let firstYear: Int
        public let firstYearMeanSeconds: Double
        public let latestYear: Int
        public let latestYearMeanSeconds: Double

        /// Fractional growth from first to latest (0.5 means +50%).
        public var creep: Double {
            guard self.firstYearMeanSeconds > 0 else { return 0 }
            return self.latestYearMeanSeconds / self.firstYearMeanSeconds - 1
        }
    }

    /// One show's median publish-to-first-listen gap.
    public struct ShowTimeToListen: Equatable, Sendable, Identifiable {
        public let id: Int64
        public let title: String
        public let medianSeconds: Double
        public let sampleCount: Int
    }

    /// Worst finishers first, capped at ``LibraryHygieneReport/maxExamples``.
    public let completions: [ShowCompletion]
    /// Fastest bloat first, capped at ``LibraryHygieneReport/maxExamples``.
    public let creeps: [ShowCreep]
    /// Fastest listeners first (news at the top, comfort at the bottom),
    /// capped at ``LibraryHygieneReport/maxExamples``.
    public let timeToListen: [ShowTimeToListen]
}

// MARK: - Podcast behaviour queries

/// The Podcasts tab's behaviour detectors (#373, ADR-077 slice 2), split from the
/// accounting slice so each file stays focused.
public extension LibraryStatsRepository {
    /// Started episodes a show needs before its completion rate means much:
    /// a two-episode show must not top the table.
    static let podcastCompletionMinimumStarted = 5
    /// Episodes a calendar year needs before its mean joins a creep row.
    static let podcastCreepMinimumEpisodesPerYear = 3
    /// First listens a show needs before its median gap is reported.
    static let podcastTimeToListenMinimumSamples = 5

    /// Runs every behaviour query in one read transaction.
    func fetchPodcastBehaviour() async throws -> LibraryPodcastBehaviourReport {
        try await self.database.read { db in
            try LibraryPodcastBehaviourReport(
                completions: Self.showCompletions(db),
                creeps: Self.showCreeps(db),
                timeToListen: Self.showTimeToListen(db)
            )
        }
    }
}

private extension LibraryStatsRepository {
    static func showCompletions(_ db: GRDB.Database) throws -> [LibraryPodcastBehaviourReport.ShowCompletion] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT podcasts.id AS id,
                   podcasts.title AS title,
                   SUM(CASE WHEN state.play_state = 'played' THEN 1 ELSE 0 END) AS played,
                   SUM(CASE WHEN state.play_state = 'inProgress' THEN 1 ELSE 0 END) AS stalled,
                   AVG(CASE WHEN state.play_state = 'inProgress' AND state.play_position > 0
                            THEN state.play_position END) AS abandon_seconds
            FROM podcast_episode_state AS state
            JOIN podcasts ON podcasts.id = state.podcast_id
            GROUP BY podcasts.id
            HAVING played + stalled >= ?
            ORDER BY CAST(played AS REAL) / (played + stalled) ASC, podcasts.title ASC
            LIMIT \(LibraryHygieneReport.maxExamples)
            """,
            arguments: [Self.podcastCompletionMinimumStarted]
        )
        return rows.compactMap { row in
            guard let id: Int64 = row["id"] else { return nil }
            return LibraryPodcastBehaviourReport.ShowCompletion(
                id: id,
                title: row["title"] ?? "",
                playedCount: row["played"] ?? 0,
                inProgressCount: row["stalled"] ?? 0,
                meanAbandonSeconds: row["abandon_seconds"]
            )
        }
    }

    static func showCreeps(_ db: GRDB.Database) throws -> [LibraryPodcastBehaviourReport.ShowCreep] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT podcasts.id AS id,
                   podcasts.title AS title,
                   CAST(strftime('%Y', episodes.published_at, 'unixepoch', 'localtime') AS INTEGER) AS year,
                   AVG(episodes.duration) AS mean_duration,
                   COUNT(*) AS episode_count
            FROM podcast_episodes AS episodes
            JOIN podcasts ON podcasts.id = episodes.podcast_id
            WHERE episodes.published_at IS NOT NULL
              AND episodes.duration IS NOT NULL AND episodes.duration > 0
            GROUP BY podcasts.id, year
            HAVING episode_count >= ?
            ORDER BY podcasts.id, year
            """,
            arguments: [Self.podcastCreepMinimumEpisodesPerYear]
        )

        struct YearRow {
            let title: String
            let year: Int
            let mean: Double
        }
        var byShow: [Int64: [YearRow]] = [:]
        for row in rows {
            guard let id: Int64 = row["id"], let year: Int = row["year"] else { continue }
            byShow[id, default: []].append(YearRow(
                title: row["title"] ?? "",
                year: year,
                mean: row["mean_duration"] ?? 0
            ))
        }
        let creeps: [LibraryPodcastBehaviourReport.ShowCreep] = byShow.compactMap { id, years in
            guard let first = years.first, let latest = years.last, first.year < latest.year else {
                return nil
            }
            return LibraryPodcastBehaviourReport.ShowCreep(
                id: id,
                title: first.title,
                firstYear: first.year,
                firstYearMeanSeconds: first.mean,
                latestYear: latest.year,
                latestYearMeanSeconds: latest.mean
            )
        }
        return Array(creeps.sorted { $0.creep > $1.creep }.prefix(LibraryHygieneReport.maxExamples))
    }

    static func showTimeToListen(_ db: GRDB.Database) throws -> [LibraryPodcastBehaviourReport.ShowTimeToListen] {
        // First listen is proxied by the earlier of completed_at and
        // last_played_at (the symmetric COALESCE keeps a lone value usable).
        let rows = try Row.fetchAll(db, sql: """
            SELECT podcasts.id AS id,
                   podcasts.title AS title,
                   MIN(COALESCE(state.completed_at, state.last_played_at),
                       COALESCE(state.last_played_at, state.completed_at)) - episodes.published_at AS gap
            FROM podcast_episode_state AS state
            JOIN podcasts ON podcasts.id = state.podcast_id
            JOIN podcast_episodes AS episodes
                ON episodes.podcast_id = state.podcast_id AND episodes.guid = state.guid
            WHERE state.play_state IN ('played', 'inProgress')
              AND episodes.published_at IS NOT NULL
              AND COALESCE(state.completed_at, state.last_played_at) IS NOT NULL
        """)

        struct GapRow {
            let title: String
            var gaps: [Double]
        }
        var byShow: [Int64: GapRow] = [:]
        for row in rows {
            guard let id: Int64 = row["id"] else { continue }
            let gap: Double = row["gap"] ?? 0
            // A pre-publish or clock-skewed listen clamps to zero.
            byShow[id, default: GapRow(title: row["title"] ?? "", gaps: [])].gaps.append(max(0, gap))
        }
        let medians: [LibraryPodcastBehaviourReport.ShowTimeToListen] = byShow.compactMap { id, show in
            guard show.gaps.count >= Self.podcastTimeToListenMinimumSamples else { return nil }
            return LibraryPodcastBehaviourReport.ShowTimeToListen(
                id: id,
                title: show.title,
                medianSeconds: Self.median(show.gaps),
                sampleCount: show.gaps.count
            )
        }
        return Array(
            medians
                .sorted { $0.medianSeconds < $1.medianSeconds }
                .prefix(LibraryHygieneReport.maxExamples)
        )
    }

    /// Middle value (mean of the middle pair for even counts).
    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
