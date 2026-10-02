import Foundation
import Persistence
import Testing
@testable import Podcasts

// MARK: - Helpers shared by the PodcastService suites

let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

/// Builds an in-memory `Database` + a `PodcastService` wired to it.
/// The `feedMock` and `artMock` are separate so artwork requests can be
/// distinguished from feed-fetch requests in tests that need the distinction.
struct TestBed {
    let db: Database
    let service: PodcastService
    let artCache: PodcastArtworkCache
    let feedMock: MockHTTPClient
    let artMock: MockHTTPClient
    let transcriptMock: MockHTTPClient
    let artTempDir: URL
    let downloadStore: DownloadStore
    let downloadRoot: URL
}

func makePodcastServiceBed(nowDate: Date = fixedNow) async throws -> TestBed {
    let db = try await Database(location: .inMemory)
    let feedMock = MockHTTPClient()
    let artMock = MockHTTPClient()
    let transcriptMock = MockHTTPClient()
    let artTemp = FileManager.default.temporaryDirectory
        .appendingPathComponent("PodcastArtworkCacheTests-\(UUID().uuidString)", isDirectory: true)
    let artCache = PodcastArtworkCache(http: artMock, root: artTemp)
    let downloadRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("PodcastDownloadsTests-\(UUID().uuidString)", isDirectory: true)
    let downloadStore = DownloadStore(root: downloadRoot)
    let service = PodcastService(
        podcastRepo: PodcastRepository(database: db),
        episodeRepo: EpisodeRepository(database: db),
        stateRepo: EpisodeStateRepository(database: db),
        transcriptRepo: TranscriptRepository(database: db),
        chaptersRepo: ChaptersRepository(database: db),
        fetcher: FeedFetcher(http: feedMock),
        artwork: artCache,
        downloadStore: downloadStore,
        transcriptHTTP: transcriptMock
    ) { nowDate }
    return TestBed(
        db: db,
        service: service,
        artCache: artCache,
        feedMock: feedMock,
        artMock: artMock,
        transcriptMock: transcriptMock,
        artTempDir: artTemp,
        downloadStore: downloadStore,
        downloadRoot: downloadRoot
    )
}

func fixtureData(named name: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"),
        "Fixture not found: \(name)"
    )
    return try Data(contentsOf: url)
}

let testFeedURL = URL(string: "https://example.com/feed.rss")!
let ep1GUID = "https://example.com/episodes/1"
let ep2GUID = "unique-guid-ep2"
