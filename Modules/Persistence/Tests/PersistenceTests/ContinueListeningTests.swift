import Foundation
import Testing
@testable import Persistence

@Suite("Continue Listening rail (ADR-054)")
struct ContinueListeningTests {
    private func makeDB() async throws -> Database {
        try await Database(location: .inMemory)
    }

    private func insertPodcast(
        in db: Database,
        feedURL: String = "https://example.test/feed.rss",
        title: String = "Test Show",
        artworkPath: String? = "/art/show.jpg",
        subscribed: Bool = true
    ) async throws -> Int64 {
        try await PodcastRepository(database: db).insert(Podcast(
            feedURL: feedURL,
            title: title,
            artworkPath: artworkPath,
            subscribed: subscribed,
            addedAt: 1_700_000_000
        ))
    }

    private func insertEpisode(
        in db: Database,
        podcastID: Int64,
        guid: String,
        title: String = "Episode",
        duration: Double? = 3600,
        artworkPath: String? = nil
    ) async throws {
        _ = try await EpisodeRepository(database: db).upsert(PodcastEpisode(
            podcastID: podcastID,
            guid: guid,
            title: title,
            audioURL: "https://example.test/\(guid).mp3",
            duration: duration,
            artworkPath: artworkPath,
            addedAt: 1_700_000_000
        ))
    }

    @Test("returns only the in-progress episode with joined content and artwork fallback")
    func inProgressOnlyWithFallback() async throws {
        let db = try await makeDB()
        let podcastID = try await insertPodcast(in: db)
        let repo = EpisodeStateRepository(database: db)
        try await self.insertEpisode(in: db, podcastID: podcastID, guid: "started", title: "Started", duration: 1800)
        try await self.insertEpisode(in: db, podcastID: podcastID, guid: "finished", title: "Finished")
        try await self.insertEpisode(in: db, podcastID: podcastID, guid: "untouched", title: "Untouched")
        try await repo.savePosition(podcastID: podcastID, guid: "started", position: 600, now: 1_700_001_000)
        try await repo.markPlayed(podcastID: podcastID, guid: "finished", now: 1_700_002_000)

        let items = try await repo.continueListening()
        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.podcastID == podcastID)
        #expect(item.guid == "started")
        #expect(item.episodeTitle == "Started")
        #expect(item.showTitle == "Test Show")
        #expect(item.playPosition == 600)
        #expect(item.duration == 1800)
        #expect(item.lastPlayedAt == 1_700_001_000)
        #expect(item.artworkPath == "/art/show.jpg", "falls back to show art when episode art is nil")
    }

    @Test("episode artwork wins over show artwork when present")
    func episodeArtworkWins() async throws {
        let db = try await makeDB()
        let podcastID = try await insertPodcast(in: db)
        let repo = EpisodeStateRepository(database: db)
        try await self.insertEpisode(
            in: db, podcastID: podcastID, guid: "ep", artworkPath: "/art/episode.jpg"
        )
        try await repo.savePosition(podcastID: podcastID, guid: "ep", position: 10, now: 1_700_001_000)

        let items = try await repo.continueListening()
        #expect(items.first?.artworkPath == "/art/episode.jpg")
    }

    @Test("orders by recency across shows, newest first, guid tiebreak")
    func recencyOrdering() async throws {
        let db = try await makeDB()
        let showA = try await insertPodcast(in: db, feedURL: "https://a.test/rss", title: "Show A")
        let showB = try await insertPodcast(in: db, feedURL: "https://b.test/rss", title: "Show B")
        let repo = EpisodeStateRepository(database: db)
        try await self.insertEpisode(in: db, podcastID: showA, guid: "a-old")
        try await self.insertEpisode(in: db, podcastID: showB, guid: "b-new")
        try await self.insertEpisode(in: db, podcastID: showA, guid: "a-tie")
        try await self.insertEpisode(in: db, podcastID: showB, guid: "b-tie")
        try await repo.savePosition(podcastID: showA, guid: "a-old", position: 5, now: 1_700_001_000)
        try await repo.savePosition(podcastID: showB, guid: "b-new", position: 5, now: 1_700_009_000)
        try await repo.savePosition(podcastID: showA, guid: "a-tie", position: 5, now: 1_700_005_000)
        try await repo.savePosition(podcastID: showB, guid: "b-tie", position: 5, now: 1_700_005_000)

        let guids = try await repo.continueListening().map(\.guid)
        #expect(guids == ["b-new", "a-tie", "b-tie", "a-old"], "descending recency, guid ASC on ties")
    }

    @Test("excludes finished and unstarted even with newer activity")
    func excludesFinishedAndUnstarted() async throws {
        let db = try await makeDB()
        let podcastID = try await insertPodcast(in: db)
        let repo = EpisodeStateRepository(database: db)
        try await self.insertEpisode(in: db, podcastID: podcastID, guid: "in-progress")
        try await self.insertEpisode(in: db, podcastID: podcastID, guid: "finished-later")
        try await repo.savePosition(podcastID: podcastID, guid: "in-progress", position: 5, now: 1_700_001_000)
        try await repo.markPlayed(podcastID: podcastID, guid: "finished-later", now: 1_700_009_000)

        let guids = try await repo.continueListening().map(\.guid)
        #expect(guids == ["in-progress"])
    }

    @Test("excludes orphaned state and unsubscribed shows")
    func excludesOrphansAndUnsubscribed() async throws {
        let db = try await makeDB()
        let subscribed = try await insertPodcast(in: db)
        let unsubscribed = try await insertPodcast(
            in: db, feedURL: "https://gone.test/rss", title: "Gone", subscribed: false
        )
        let repo = EpisodeStateRepository(database: db)
        // Orphaned: a state row with no matching content row (pruned episode).
        try await repo.savePosition(podcastID: subscribed, guid: "pruned", position: 5, now: 1_700_002_000)
        // Unsubscribed show with a real in-progress episode.
        try await self.insertEpisode(in: db, podcastID: unsubscribed, guid: "u-ep")
        try await repo.savePosition(podcastID: unsubscribed, guid: "u-ep", position: 5, now: 1_700_003_000)
        // The one item that should survive.
        try await self.insertEpisode(in: db, podcastID: subscribed, guid: "keeper")
        try await repo.savePosition(podcastID: subscribed, guid: "keeper", position: 5, now: 1_700_001_000)

        let guids = try await repo.continueListening().map(\.guid)
        #expect(guids == ["keeper"])
    }

    @Test("honours the limit")
    func honoursLimit() async throws {
        let db = try await makeDB()
        let podcastID = try await insertPodcast(in: db)
        let repo = EpisodeStateRepository(database: db)
        for i in 0 ..< 4 {
            try await self.insertEpisode(in: db, podcastID: podcastID, guid: "ep-\(i)")
            try await repo.savePosition(
                podcastID: podcastID, guid: "ep-\(i)", position: 5, now: Double(1_700_001_000 + i)
            )
        }
        let items = try await repo.continueListening(limit: 3)
        #expect(items.count == 3)
    }

    @Test("observation emits on position writes and drops on markPlayed")
    func observationTracksWrites() async throws {
        let db = try await makeDB()
        let podcastID = try await insertPodcast(in: db)
        let repo = EpisodeStateRepository(database: db)
        try await self.insertEpisode(in: db, podcastID: podcastID, guid: "ep")

        let stream = await repo.observeContinueListening()
        var iterator = stream.makeAsyncIterator()

        let initial = try await iterator.next()
        #expect(initial?.isEmpty == true)

        try await repo.savePosition(podcastID: podcastID, guid: "ep", position: 5, now: 1_700_001_000)
        let afterStart = try await iterator.next()
        #expect(afterStart?.map(\.guid) == ["ep"])

        try await repo.markPlayed(podcastID: podcastID, guid: "ep", now: 1_700_002_000)
        let afterFinish = try await iterator.next()
        #expect(afterFinish?.isEmpty == true)
    }
}
