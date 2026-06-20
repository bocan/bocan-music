import Foundation
import Persistence
import Testing
@testable import Podcasts

@Suite("TranscriptFetcher")
struct TranscriptFetcherTests {
    private func makeDB() async throws -> Database {
        try await Database(location: .inMemory)
    }

    private func makePodcast(_ db: Database) async throws -> Int64 {
        try await PodcastRepository(database: db).insert(
            Podcast(feedURL: "https://example.test/feed", title: "Show", addedAt: 1)
        )
    }

    @Test("fetchAndStore stores the served body, inferred format, language, and source URL")
    func fetchAndStoreWritesRow() async throws {
        let db = try await makeDB()
        let pid = try await makePodcast(db)
        let repo = TranscriptRepository(database: db)
        let mock = MockHTTPClient()
        let body = "WEBVTT\n\n00:00.000 --> 00:01.000\nHello"
        mock.handler = { _ in
            (Data(body.utf8), HTTPURLResponse(
                url: URL(string: "https://example.test/t.vtt")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/vtt"]
            )!)
        }
        let fetcher = TranscriptFetcher(http: mock, repo: repo, now: { Date(timeIntervalSince1970: 5) })
        let url = try #require(URL(string: "https://example.test/t.vtt"))
        let record = try await fetcher.fetchAndStore(
            podcastID: pid, guid: "ep1", transcriptURL: url, language: "en"
        )
        #expect(record.content == body)
        #expect(record.format == .vtt)
        #expect(record.sourceURL == "https://example.test/t.vtt")
        #expect(record.language == "en")
        #expect(record.fetchedAt == 5)

        let stored = try await repo.fetch(podcastID: pid, guid: "ep1")
        #expect(stored?.content == body)
    }

    @Test("non-http transcript URL is rejected")
    func rejectsNonHTTP() async throws {
        let db = try await makeDB()
        let fetcher = TranscriptFetcher(http: MockHTTPClient(), repo: TranscriptRepository(database: db))
        let url = try #require(URL(string: "ftp://example.test/t.vtt"))
        await #expect(throws: PodcastsError.self) {
            _ = try await fetcher.fetchAndStore(podcastID: 1, guid: "ep1", transcriptURL: url, language: nil)
        }
    }
}
