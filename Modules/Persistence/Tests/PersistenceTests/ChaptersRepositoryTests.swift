import Foundation
import Testing
@testable import Persistence

@Suite("ChaptersRepository", .serialized)
struct ChaptersRepositoryTests {
    private static let url = "https://example.test/ep1/chapters.json"
    private static let body = #"{"version":"1.2.0","chapters":[{"startTime":0,"title":"Intro"}]}"#

    private func makeDB() async throws -> Database {
        try await Database(location: .inMemory)
    }

    /// Inserts a show with one episode whose `chapters_url` is `chaptersURL`.
    private func seed(_ db: Database, guid: String = "g", chaptersURL: String? = Self.url) async throws -> Int64 {
        let podcastID = try await PodcastRepository(database: db).insert(
            Podcast(feedURL: "https://example.test/feed", title: "Show", addedAt: 1_700_000_000)
        )
        try await self.setEpisode(db, podcastID: podcastID, guid: guid, chaptersURL: chaptersURL)
        return podcastID
    }

    private func setEpisode(_ db: Database, podcastID: Int64, guid: String, chaptersURL: String?) async throws {
        _ = try await EpisodeRepository(database: db).upsert(PodcastEpisode(
            podcastID: podcastID,
            guid: guid,
            title: "Episode",
            audioURL: "https://example.test/\(guid).mp3",
            chaptersURL: chaptersURL,
            addedAt: 0
        ))
    }

    @Test("every column round-trips, and an update replaces the document")
    func upsertCarriesEveryColumn() async throws {
        let db = try await makeDB()
        let podcastID = try await seed(db)
        let repo = ChaptersRepository(database: db)

        try await repo.upsert(PodcastChapters(podcastID: podcastID, guid: "g", content: Self.body, sourceURL: Self.url))
        var stored = try #require(try await repo.fetchCurrent(podcastID: podcastID, guid: "g"))
        #expect(stored.podcastID == podcastID)
        #expect(stored.guid == "g")
        #expect(stored.content == Self.body)
        #expect(stored.sourceURL == Self.url)

        let newer = #"{"chapters":[{"startTime":5,"title":"Cold open"}]}"#
        try await repo.upsert(PodcastChapters(podcastID: podcastID, guid: "g", content: newer, sourceURL: Self.url))
        stored = try #require(try await repo.fetchCurrent(podcastID: podcastID, guid: "g"))
        #expect(stored.content == newer)
    }

    @Test("a miss returns nil")
    func miss() async throws {
        let db = try await makeDB()
        let podcastID = try await seed(db)
        #expect(try await ChaptersRepository(database: db).fetchCurrent(podcastID: podcastID, guid: "g") == nil)
    }

    @Test("a document stops being current when the episode's chapters URL moves or goes")
    func staleSourceIsNotCurrent() async throws {
        let db = try await makeDB()
        let podcastID = try await seed(db)
        let repo = ChaptersRepository(database: db)
        try await repo.upsert(PodcastChapters(podcastID: podcastID, guid: "g", content: Self.body, sourceURL: Self.url))
        #expect(try await repo.guidsWithCurrentChapters(podcastID: podcastID) == ["g"])

        try await self.setEpisode(db, podcastID: podcastID, guid: "g", chaptersURL: "https://example.test/moved.json")
        #expect(try await repo.fetchCurrent(podcastID: podcastID, guid: "g") == nil)
        #expect(try await repo.guidsWithCurrentChapters(podcastID: podcastID).isEmpty)

        try await self.setEpisode(db, podcastID: podcastID, guid: "g", chaptersURL: nil)
        #expect(try await repo.fetchCurrent(podcastID: podcastID, guid: "g") == nil)
    }

    @Test("guidsWithCurrentChapters lists only the show's cached episodes")
    func guidsPerShow() async throws {
        let db = try await makeDB()
        let podcastID = try await seed(db, guid: "a")
        try await self.setEpisode(db, podcastID: podcastID, guid: "b", chaptersURL: Self.url)
        let repo = ChaptersRepository(database: db)
        try await repo.upsert(PodcastChapters(podcastID: podcastID, guid: "a", content: Self.body, sourceURL: Self.url))

        #expect(try await repo.guidsWithCurrentChapters(podcastID: podcastID) == ["a"])
        #expect(try await repo.guidsWithCurrentChapters(podcastID: podcastID + 1).isEmpty)
    }

    @Test("the table has exactly the columns M054 created")
    func tableColumns() async throws {
        let db = try await makeDB()
        let columns = try await db.read { grdb in
            try String.fetchAll(grdb, sql: "SELECT name FROM pragma_table_info('podcast_episode_chapters')")
        }
        #expect(columns == ["podcast_id", "guid", "content", "source_url"])
    }

    @Test("unsubscribing drops the cached document")
    func cascadesWithShow() async throws {
        let db = try await makeDB()
        let podcastID = try await seed(db)
        try await ChaptersRepository(database: db).upsert(
            PodcastChapters(podcastID: podcastID, guid: "g", content: Self.body, sourceURL: Self.url)
        )
        try await db.write { grdb in
            try grdb.execute(sql: "DELETE FROM podcasts WHERE id = ?", arguments: [podcastID])
        }
        let remaining = try await db.read { grdb in
            try Int.fetchOne(grdb, sql: "SELECT COUNT(*) FROM podcast_episode_chapters") ?? -1
        }
        #expect(remaining == 0)
    }
}
