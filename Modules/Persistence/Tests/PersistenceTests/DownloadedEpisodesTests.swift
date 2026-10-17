import Foundation
import Testing
@testable import Persistence

/// The cross-show downloads read behind the Podcasts Downloaded view (#651).
@Suite("EpisodeRepository downloads", .serialized)
struct DownloadedEpisodesTests {
    private func makeDB() async throws -> Database {
        try await Database(location: .inMemory)
    }

    private func insertShow(_ db: Database, title: String) async throws -> Int64 {
        try await PodcastRepository(database: db).insert(Podcast(
            feedURL: "https://example.test/\(title).rss",
            title: title,
            addedAt: 1_700_000_000
        ))
    }

    private func episode(_ podcastID: Int64, _ guid: String, publishedAt: Double) -> PodcastEpisode {
        PodcastEpisode(
            podcastID: podcastID,
            guid: guid,
            title: guid,
            audioURL: "https://cdn.example.test/\(guid).mp3",
            duration: 1800,
            publishedAt: publishedAt,
            addedAt: 1_700_000_000
        )
    }

    private func markDownloaded(_ db: Database, _ podcastID: Int64, _ guid: String) async throws {
        try await EpisodeStateRepository(database: db).setDownloadState(
            podcastID: podcastID,
            guid: guid,
            state: .downloaded,
            path: "/tmp/\(guid).mp3",
            bytes: 1000
        )
    }

    @Test("Lists downloads from every show, newest first, and nothing else")
    func listsDownloadsAcrossShows() async throws {
        let db = try await makeDB()
        let episodes = EpisodeRepository(database: db)
        let news = try await insertShow(db, title: "News")
        let talk = try await insertShow(db, title: "Talk")
        try await episodes.upsertAll([
            self.episode(news, "n-old", publishedAt: 100),
            self.episode(news, "n-new", publishedAt: 300),
            self.episode(news, "n-streamed", publishedAt: 400),
            self.episode(talk, "t-mid", publishedAt: 200),
        ])
        try await self.markDownloaded(db, news, "n-old")
        try await self.markDownloaded(db, news, "n-new")
        try await self.markDownloaded(db, talk, "t-mid")
        // A played download stays a download: the view shows it with its badge.
        try await EpisodeStateRepository(database: db).markPlayed(podcastID: talk, guid: "t-mid", now: 1)

        let items = try await episodes.fetchDownloadedListItems()
        #expect(items.map(\.episode.guid) == ["n-new", "t-mid", "n-old"])
        let anyNotDownloaded = items.contains { $0.state?.downloadState != .downloaded }
        #expect(!anyNotDownloaded)
        #expect(items.first { $0.episode.guid == "t-mid" }?.state?.playState == .played)
    }

    @Test("A state row whose episode left the feed is not listed")
    func skipsOrphanState() async throws {
        let db = try await makeDB()
        let episodes = EpisodeRepository(database: db)
        let show = try await insertShow(db, title: "Pruned")
        try await episodes.upsertAll([
            self.episode(show, "kept", publishedAt: 100),
            self.episode(show, "gone", publishedAt: 200),
        ])
        try await self.markDownloaded(db, show, "kept")
        try await self.markDownloaded(db, show, "gone")
        try await episodes.pruneEpisodes(podcastID: show, keepGUIDs: ["kept"])

        let items = try await episodes.fetchDownloadedListItems()
        #expect(items.map(\.episode.guid) == ["kept"])
    }

    @Test("The observation re-emits when a download lands and when one is removed")
    func observationFollowsDownloads() async throws {
        let db = try await makeDB()
        let episodes = EpisodeRepository(database: db)
        let show = try await insertShow(db, title: "Live")
        try await episodes.upsert(self.episode(show, "ep", publishedAt: 100))

        var iterator = await episodes.observeDownloadedListItems().makeAsyncIterator()
        #expect(try await iterator.next()?.isEmpty == true)

        try await self.markDownloaded(db, show, "ep")
        #expect(try await iterator.next()?.map(\.episode.guid) == ["ep"])

        try await EpisodeStateRepository(database: db).setDownloadState(
            podcastID: show, guid: "ep", state: .none, path: nil, bytes: nil
        )
        #expect(try await iterator.next()?.isEmpty == true)
    }
}
