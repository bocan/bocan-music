import Foundation
import Testing
@testable import Persistence

/// The podcast accounting queries (#373, ADR-077 slice 1), in their own suite
/// like the other report slices.
@Suite("LibraryStatsRepository podcasts")
struct LibraryStatsPodcastTests {
    private func makeDB() async throws -> Database {
        try await Database(location: .inMemory)
    }

    @discardableResult
    private func seedShow(_ db: Database, title: String) async throws -> Int64 {
        try await db.write { db in
            try db.execute(
                sql: "INSERT INTO podcasts (feed_url, title, added_at) VALUES (?, ?, 0)",
                arguments: ["https://example.com/\(title).xml", title]
            )
            return db.lastInsertedRowID
        }
    }

    /// Play/download state for one seeded episode.
    private struct EpisodeSpec {
        var duration: Double = 3600
        var publishedAt: Double = 1000
        var playState = "unplayed"
        var position: Double = 0
        var lastPlayedAt: Double?
        var completedAt: Double?
        var downloadState = "none"
        var downloadPath: String?
        var downloadBytes: Int64?
    }

    private func seedEpisode(_ db: Database, showID: Int64, guid: String, spec: EpisodeSpec) async throws {
        try await db.write { db in
            try db.execute(
                sql: """
                INSERT INTO podcast_episodes (podcast_id, guid, title, audio_url, duration, published_at, added_at)
                VALUES (?, ?, ?, 'https://example.com/audio.mp3', ?, ?, 0)
                """,
                arguments: [showID, guid, guid, spec.duration, spec.publishedAt]
            )
            try db.execute(
                sql: """
                INSERT INTO podcast_episode_state
                    (podcast_id, guid, play_position, play_state, last_played_at, completed_at,
                     download_state, download_path, download_bytes)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    showID,
                    guid,
                    spec.position,
                    spec.playState,
                    spec.lastPlayedAt,
                    spec.completedAt,
                    spec.downloadState,
                    spec.downloadPath,
                    spec.downloadBytes,
                ]
            )
        }
    }

    @Test("Backlog counts unplayed in full and in-progress remainders")
    func backlogDebt() async throws {
        let db = try await makeDB()
        let show = try await seedShow(db, title: "Debt")
        try await self.seedEpisode(db, showID: show, guid: "e1", spec: .init(duration: 3600))
        try await self.seedEpisode(db, showID: show, guid: "e2", spec: .init(
            duration: 3600,
            playState: "inProgress",
            position: 1800
        ))
        try await self.seedEpisode(db, showID: show, guid: "e3", spec: .init(
            duration: 3600,
            playState: "played",
            completedAt: 500
        ))
        // An episode with no state row at all is unplayed by definition.
        try await db.write { db in
            try db.execute(
                sql: """
                INSERT INTO podcast_episodes (podcast_id, guid, title, audio_url, duration, published_at, added_at)
                VALUES (?, 'e4', 'e4', 'https://example.com/a.mp3', 600, 1000, 0)
                """,
                arguments: [show]
            )
        }
        let report = try await LibraryStatsRepository(database: db).fetchPodcastReport()
        #expect(report.subscribedShowCount == 1)
        #expect(report.backlogSeconds == 3600 + 1800 + 600)
    }

    @Test("The listening rate window keeps recent touches and drops old ones")
    func listeningRate() async throws {
        let db = try await makeDB()
        let now = Date().timeIntervalSince1970
        let show = try await seedShow(db, title: "Rate")
        try await self.seedEpisode(db, showID: show, guid: "recent", spec: .init(
            duration: 5200,
            playState: "played",
            completedAt: now - 7 * 86400
        ))
        try await self.seedEpisode(db, showID: show, guid: "partial", spec: .init(
            duration: 3600,
            playState: "inProgress",
            position: 1000,
            lastPlayedAt: now - 14 * 86400
        ))
        try await self.seedEpisode(db, showID: show, guid: "ancient", spec: .init(
            duration: 9000,
            playState: "played",
            completedAt: now - 300 * 86400
        ))

        let report = try await LibraryStatsRepository(database: db).fetchPodcastReport()
        let expected = (5200.0 + 1000.0) / Double(LibraryStatsRepository.podcastRateWindowWeeks)
        #expect(abs(report.weeklyListeningSeconds - expected) < 0.001)
    }

    @Test("Dead feeds are subscribed shows with no episode in 180 days")
    func deadFeeds() async throws {
        let db = try await makeDB()
        let now = Date().timeIntervalSince1970
        let dead = try await seedShow(db, title: "Dead Air")
        try await self.seedEpisode(db, showID: dead, guid: "old", spec: .init(publishedAt: now - 200 * 86400))
        let alive = try await seedShow(db, title: "Alive")
        try await self.seedEpisode(db, showID: alive, guid: "old", spec: .init(publishedAt: now - 200 * 86400))
        try await self.seedEpisode(db, showID: alive, guid: "new", spec: .init(publishedAt: now - 5 * 86400))

        let report = try await LibraryStatsRepository(database: db).fetchPodcastReport()
        #expect(report.deadFeedCount == 1)
        #expect(report.deadFeeds.first?.id == dead)
        #expect(report.deadFeeds.first?.title == "Dead Air")
    }

    @Test("Unplayed downloads count per show with bytes, largest hoard first")
    func unplayedDownloads() async throws {
        let db = try await makeDB()
        let hoarder = try await seedShow(db, title: "Hoard")
        for (index, bytes) in [50_000_000, 60_000_000].enumerated() {
            try await self.seedEpisode(db, showID: hoarder, guid: "h\(index)", spec: .init(
                downloadState: "downloaded",
                downloadPath: "/tmp/h\(index).mp3",
                downloadBytes: Int64(bytes)
            ))
        }
        let listener = try await seedShow(db, title: "Diligent")
        try await self.seedEpisode(db, showID: listener, guid: "d1", spec: .init(
            playState: "played",
            completedAt: 1000,
            downloadState: "downloaded",
            downloadPath: "/tmp/d1.mp3",
            downloadBytes: 70_000_000
        ))
        try await self.seedEpisode(db, showID: listener, guid: "d2", spec: .init(
            downloadState: "downloaded",
            downloadPath: "/tmp/d2.mp3",
            downloadBytes: 10_000_000
        ))

        let report = try await LibraryStatsRepository(database: db).fetchPodcastReport()
        #expect(report.unplayedDownloadShowCount == 2)
        #expect(report.unplayedDownloadEpisodeCount == 3)
        #expect(report.unplayedDownloadBytes == 120_000_000)
        #expect(report.unplayedDownloads.first?.id == hoarder)
        #expect(report.unplayedDownloads.first?.bytes == 110_000_000)
    }

    @Test("Reapable storage is played, aged past 90 days, and still on disk")
    func reapableStorage() async throws {
        let db = try await makeDB()
        let now = Date().timeIntervalSince1970
        let show = try await seedShow(db, title: "Reap")
        try await self.seedEpisode(db, showID: show, guid: "aged", spec: .init(
            playState: "played",
            completedAt: now - 100 * 86400,
            downloadState: "downloaded",
            downloadPath: "/tmp/aged.mp3",
            downloadBytes: 40_000_000
        ))
        try await self.seedEpisode(db, showID: show, guid: "fresh", spec: .init(
            playState: "played",
            completedAt: now - 10 * 86400,
            downloadState: "downloaded",
            downloadPath: "/tmp/fresh.mp3",
            downloadBytes: 30_000_000
        ))
        try await self.seedEpisode(db, showID: show, guid: "gone", spec: .init(
            playState: "played",
            completedAt: now - 100 * 86400,
            downloadState: "none",
            downloadBytes: 20_000_000
        ))

        let report = try await LibraryStatsRepository(database: db).fetchPodcastReport()
        #expect(report.reapableEpisodeCount == 1)
        #expect(report.reapableBytes == 40_000_000)
    }

    /// Epoch seconds for a wall-clock moment in the current time zone,
    /// matching the SQL `localtime` year bucketing.
    private func epoch(_ year: Int, _ month: Int, _ day: Int) throws -> Int64 {
        let components = DateComponents(year: year, month: month, day: day, hour: 12)
        let date = try #require(Calendar.current.date(from: components))
        return Int64(date.timeIntervalSince1970)
    }

    @Test("Completion rates need five starts, worst finishers first")
    func completionRates() async throws {
        let db = try await makeDB()
        let finisher = try await seedShow(db, title: "Finisher")
        for index in 0 ..< 6 {
            try await self.seedEpisode(db, showID: finisher, guid: "f\(index)", spec: .init(playState: "played"))
        }
        for index in 0 ..< 4 {
            try await self.seedEpisode(db, showID: finisher, guid: "fp\(index)", spec: .init(
                playState: "inProgress",
                position: 840
            ))
        }
        let quitter = try await seedShow(db, title: "Quitter")
        try await self.seedEpisode(db, showID: quitter, guid: "q0", spec: .init(playState: "played"))
        for index in 0 ..< 5 {
            try await self.seedEpisode(db, showID: quitter, guid: "qp\(index)", spec: .init(
                playState: "inProgress",
                position: 300
            ))
        }
        let tiny = try await seedShow(db, title: "Tiny")
        try await self.seedEpisode(db, showID: tiny, guid: "t0", spec: .init(playState: "played"))

        let report = try await LibraryStatsRepository(database: db).fetchPodcastBehaviour()
        #expect(report.completions.count == 2, "a one-start show cannot join the table")
        let worst = try #require(report.completions.first)
        #expect(worst.id == quitter, "the worst finisher sorts first")
        #expect(abs(worst.completionRate - 1.0 / 6.0) < 0.001)
        let better = try #require(report.completions.last)
        #expect(better.id == finisher)
        #expect(abs(better.completionRate - 0.6) < 0.001)
        #expect(better.meanAbandonSeconds == 840)
    }

    @Test("Length creep compares first and latest qualifying years")
    func lengthCreep() async throws {
        let db = try await makeDB()
        let bloater = try await seedShow(db, title: "Bloater")
        for index in 0 ..< 3 {
            try await self.seedEpisode(db, showID: bloater, guid: "b19-\(index)", spec: .init(
                duration: 1800,
                publishedAt: Double(self.epoch(2019, 6, index + 10))
            ))
        }
        // A two-episode year stays below the qualifying minimum.
        for index in 0 ..< 2 {
            try await self.seedEpisode(db, showID: bloater, guid: "b22-\(index)", spec: .init(
                duration: 9999,
                publishedAt: Double(self.epoch(2022, 6, index + 10))
            ))
        }
        for index in 0 ..< 3 {
            try await self.seedEpisode(db, showID: bloater, guid: "b25-\(index)", spec: .init(
                duration: 2700,
                publishedAt: Double(self.epoch(2025, 6, index + 10))
            ))
        }
        let steady = try await seedShow(db, title: "One Season")
        for index in 0 ..< 4 {
            try await self.seedEpisode(db, showID: steady, guid: "s\(index)", spec: .init(
                duration: 1800,
                publishedAt: Double(self.epoch(2024, 6, index + 10))
            ))
        }

        let report = try await LibraryStatsRepository(database: db).fetchPodcastBehaviour()
        #expect(report.creeps.count == 1, "a single-year show has no creep to measure")
        let creep = try #require(report.creeps.first)
        #expect(creep.id == bloater)
        #expect(creep.firstYear == 2019)
        #expect(creep.latestYear == 2025)
        #expect(creep.firstYearMeanSeconds == 1800)
        #expect(creep.latestYearMeanSeconds == 2700)
        #expect(abs(creep.creep - 0.5) < 0.001)
    }

    @Test("Time-to-listen medians clamp pre-publish gaps and need five samples")
    func timeToListen() async throws {
        let db = try await makeDB()
        let now = Date().timeIntervalSince1970
        let published = now - 30 * 86400
        let news = try await seedShow(db, title: "News")
        let offsets: [Double] = [-100, 3600, 7200, 10800, 360_000]
        for (index, offset) in offsets.enumerated() {
            try await self.seedEpisode(db, showID: news, guid: "n\(index)", spec: .init(
                publishedAt: published,
                playState: "played",
                completedAt: published + offset
            ))
        }
        let sparse = try await seedShow(db, title: "Sparse")
        for index in 0 ..< 4 {
            try await self.seedEpisode(db, showID: sparse, guid: "s\(index)", spec: .init(
                publishedAt: published,
                playState: "played",
                completedAt: published + 500
            ))
        }

        let report = try await LibraryStatsRepository(database: db).fetchPodcastBehaviour()
        #expect(report.timeToListen.count == 1, "four samples are not a habit")
        let median = try #require(report.timeToListen.first)
        #expect(median.id == news)
        #expect(median.sampleCount == 5)
        #expect(median.medianSeconds == 7200, "the negative gap clamps to zero and the median holds")
    }

    @Test("Reapable identities match the reapable count's filter exactly")
    func reapableIdentities() async throws {
        let db = try await makeDB()
        let now = Date().timeIntervalSince1970
        let show = try await seedShow(db, title: "Reap IDs")
        try await self.seedEpisode(db, showID: show, guid: "aged", spec: .init(
            playState: "played",
            completedAt: now - 100 * 86400,
            downloadState: "downloaded",
            downloadPath: "/tmp/aged.mp3",
            downloadBytes: 1000
        ))
        try await self.seedEpisode(db, showID: show, guid: "fresh", spec: .init(
            playState: "played",
            completedAt: now - 5 * 86400,
            downloadState: "downloaded",
            downloadPath: "/tmp/fresh.mp3",
            downloadBytes: 1000
        ))

        let repo = LibraryStatsRepository(database: db)
        let identities = try await repo.fetchReapableEpisodes()
        #expect(identities.count == 1)
        #expect(identities.first?.podcastID == show)
        #expect(identities.first?.guid == "aged")
        let report = try await repo.fetchPodcastReport()
        #expect(identities.count == report.reapableEpisodeCount, "the action must cover exactly what the report promises")
    }

    @Test("An empty library reports zeroes")
    func emptyReport() async throws {
        let db = try await makeDB()
        let report = try await LibraryStatsRepository(database: db).fetchPodcastReport()
        #expect(report.subscribedShowCount == 0)
        #expect(report.backlogSeconds == 0)
        #expect(report.weeklyListeningSeconds == 0)
        #expect(report.deadFeeds.isEmpty)
        #expect(report.reapableBytes == 0)
    }
}
