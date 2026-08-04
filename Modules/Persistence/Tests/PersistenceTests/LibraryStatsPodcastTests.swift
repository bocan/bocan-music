import Foundation
import Testing
@testable import Persistence

/// The podcast accounting queries (#373, phase 26-1), in their own suite
/// like the other report slices.
@Suite("LibraryStatsRepository podcasts")
struct LibraryStatsPodcastTests {
    private func makeDB() async throws -> Database {
        try await Database(location: .inMemory)
    }

    @discardableResult
    private func seedShow(_ db: Database, title: String, subscribed: Bool = true) async throws -> Int64 {
        try await db.write { db in
            try db.execute(
                sql: "INSERT INTO podcasts (feed_url, title, subscribed, added_at) VALUES (?, ?, ?, 0)",
                arguments: ["https://example.com/\(title).xml", title, subscribed]
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
        // Unsubscribed shows contribute nothing.
        let gone = try await seedShow(db, title: "Gone", subscribed: false)
        try await self.seedEpisode(db, showID: gone, guid: "g1", spec: .init(duration: 9999))

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
        let unsubscribed = try await seedShow(db, title: "Left Behind", subscribed: false)
        try await self.seedEpisode(db, showID: unsubscribed, guid: "old", spec: .init(publishedAt: now - 400 * 86400))

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
