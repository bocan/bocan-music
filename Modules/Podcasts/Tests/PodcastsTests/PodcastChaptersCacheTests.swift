import Foundation
import Persistence
import Testing
@testable import Podcasts

// MARK: - Helpers

private let chaptersURL = "https://example.com/ep1-chapters.json"
private let guid = "guid-ep1"

/// A `PodcastService` over an in-memory database holding one show with one
/// episode whose `chapters_url` is `chaptersURL`. Only the chapters mock is
/// ever reached; the feed and artwork clients are inert.
private struct ChaptersBed {
    let db: Database
    let service: PodcastService
    let chaptersMock: MockHTTPClient
    let recorder: RequestRecorder
    let repo: ChaptersRepository
    let podcastID: Int64
}

private func makeBed(episodeChaptersURL: String? = chaptersURL) async throws -> ChaptersBed {
    let db = try await Database(location: .inMemory)
    let chaptersMock = MockHTTPClient()
    let artTemp = FileManager.default.temporaryDirectory
        .appendingPathComponent("PodcastChaptersCacheTests-\(UUID().uuidString)", isDirectory: true)
    let repo = ChaptersRepository(database: db)
    let service = PodcastService(
        podcastRepo: PodcastRepository(database: db),
        episodeRepo: EpisodeRepository(database: db),
        stateRepo: EpisodeStateRepository(database: db),
        transcriptRepo: TranscriptRepository(database: db),
        chaptersRepo: repo,
        fetcher: FeedFetcher(http: MockHTTPClient()),
        artwork: PodcastArtworkCache(http: MockHTTPClient(), root: artTemp),
        chaptersFetcher: ChaptersFetcher(http: chaptersMock)
    )
    let podcastID = try await PodcastRepository(database: db).insert(
        Podcast(feedURL: "https://example.com/feed.rss", title: "Show", addedAt: 1_700_000_000)
    )
    _ = try await EpisodeRepository(database: db).upsert(PodcastEpisode(
        podcastID: podcastID,
        guid: guid,
        title: "Episode 1",
        audioURL: "https://example.com/ep1.mp3",
        chaptersURL: episodeChaptersURL,
        addedAt: 1_700_000_000
    ))
    return ChaptersBed(
        db: db,
        service: service,
        chaptersMock: chaptersMock,
        recorder: RequestRecorder(),
        repo: repo,
        podcastID: podcastID
    )
}

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

private func respond(_ bed: ChaptersBed, with body: Data, status: Int = 200) {
    let recorder = bed.recorder
    bed.chaptersMock.handler = { request in
        recorder.record(request)
        return (body, HTTPURLResponse(
            url: URL(string: chaptersURL)!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!)
    }
}

// MARK: - Tests

@Suite("PodcastService chapters cache", .serialized)
struct PodcastChaptersCacheTests {
    @Test("chapters fetched once are stored verbatim with their source URL")
    func fetchStoresDocument() async throws {
        let bed = try await makeBed()
        let body = try fixture("chapters-pc20.json")
        respond(bed, with: body)

        let chapters = try await bed.service.chapters(podcastID: bed.podcastID, guid: guid)
        #expect(chapters.map(\.title) == ["Intro", "Sponsor", "Main Topic"])

        let stored = try #require(try await bed.repo.fetchCurrent(podcastID: bed.podcastID, guid: guid))
        #expect(stored.podcastID == bed.podcastID)
        #expect(stored.guid == guid)
        #expect(Data(stored.content.utf8) == body)
        #expect(stored.sourceURL == chaptersURL)

        // The second call is served by the in-memory cache: one request in all.
        _ = try await bed.service.chapters(podcastID: bed.podcastID, guid: guid)
        #expect(bed.recorder.requests.count == 1)
    }

    @Test("a failed fetch falls back to the stored document")
    func failedFetchFallsBack() async throws {
        let bed = try await makeBed()
        let body = try fixture("chapters-pc20.json")
        try await bed.repo.upsert(PodcastChapters(
            podcastID: bed.podcastID,
            guid: guid,
            content: #require(String(data: body, encoding: .utf8)),
            sourceURL: chaptersURL
        ))
        bed.chaptersMock.handler = { _ in throw URLError(.notConnectedToInternet) }

        let chapters = try await bed.service.chapters(podcastID: bed.podcastID, guid: guid)
        #expect(chapters.map(\.title) == ["Intro", "Sponsor", "Main Topic"])
    }

    @Test("a failed fetch with nothing stored still throws")
    func failedFetchWithoutCacheThrows() async throws {
        let bed = try await makeBed()
        bed.chaptersMock.handler = { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: PodcastsError.self) {
            _ = try await bed.service.chapters(podcastID: bed.podcastID, guid: guid)
        }
    }

    @Test("a document with no usable chapters is not stored")
    func emptyDocumentIsNotStored() async throws {
        let bed = try await makeBed()
        respond(bed, with: Data(#"{ "chapters": [] }"#.utf8))

        #expect(try await bed.service.chapters(podcastID: bed.podcastID, guid: guid).isEmpty)
        #expect(try await bed.repo.fetchCurrent(podcastID: bed.podcastID, guid: guid) == nil)
    }

    @Test("cacheChapters warms the cache and swallows a failed fetch")
    func cacheChaptersWarmsAndDegrades() async throws {
        let bed = try await makeBed()
        respond(bed, with: Data(), status: 500)
        await bed.service.cacheChapters(podcastID: bed.podcastID, guid: guid)
        #expect(try await bed.repo.fetchCurrent(podcastID: bed.podcastID, guid: guid) == nil)

        try respond(bed, with: fixture("chapters-pc20.json"))
        await bed.service.cacheChapters(podcastID: bed.podcastID, guid: guid)
        #expect(try await bed.repo.fetchCurrent(podcastID: bed.podcastID, guid: guid) != nil)
    }

    @Test("an episode with no chapters URL makes no request and stores nothing")
    func noChaptersURL() async throws {
        let bed = try await makeBed(episodeChaptersURL: nil)
        try respond(bed, with: fixture("chapters-pc20.json"))

        await bed.service.cacheChapters(podcastID: bed.podcastID, guid: guid)
        #expect(bed.recorder.requests.isEmpty)
        #expect(try await bed.repo.guidsWithCurrentChapters(podcastID: bed.podcastID).isEmpty)
    }
}
