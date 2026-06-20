import Foundation
import Persistence
import Testing
@testable import Podcasts

@Suite("PodcastService OPML import", .serialized)
struct OPMLImportTests {
    private struct Bed {
        let service: PodcastService
        let feedMock: MockHTTPClient
    }

    private func makeBed() async throws -> Bed {
        let db = try await Database(location: .inMemory)
        let feedMock = MockHTTPClient()
        let artTemp = FileManager.default.temporaryDirectory
            .appendingPathComponent("OPMLImportTests-\(UUID().uuidString)", isDirectory: true)
        let service = PodcastService(
            podcastRepo: PodcastRepository(database: db),
            episodeRepo: EpisodeRepository(database: db),
            stateRepo: EpisodeStateRepository(database: db),
            transcriptRepo: TranscriptRepository(database: db),
            fetcher: FeedFetcher(http: feedMock),
            artwork: PodcastArtworkCache(http: MockHTTPClient(), root: artTemp),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        return Bed(service: service, feedMock: feedMock)
    }

    private func rssData() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "rss-full.xml", withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private static func ok(_ url: URL, _ body: Data) -> (Data, HTTPURLResponse) {
        (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    private static func serverError(_ url: URL) -> (Data, HTTPURLResponse) {
        (Data(), HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!)
    }

    private final class ProgressBox: @unchecked Sendable {
        var calls: [(Int, Int)] = []
    }

    @Test("dedupes against existing subscriptions, subscribes the rest, collects failures")
    func importPartitionsAndReportsFailures() async throws {
        let bed = try await makeBed()
        let rss = try rssData()
        bed.feedMock.handler = { request in
            let url = request.url ?? URL(string: "https://invalid.example.com")!
            return (url.host?.contains("broken") ?? false) ? Self.serverError(url) : Self.ok(url, rss)
        }

        // Pre-subscribe an existing feed (stored as https://existing.example.com/feed).
        _ = try await bed.service.subscribe(feedURL: #require(URL(string: "https://existing.example.com/feed")))

        // The existing feed appears as an http + www. variant (dupe); one new feed; one broken feed.
        let opml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <body>
            <outline type="rss" text="Existing (variant)" xmlUrl="http://www.existing.example.com/feed"/>
            <outline type="rss" text="Fresh Show" xmlUrl="https://fresh.example.com/feed"/>
            <outline type="rss" text="Broken Show" xmlUrl="https://broken.example.com/feed"/>
          </body>
        </opml>
        """

        let progress = ProgressBox()
        let summary = try await bed.service.importOPML(data: Data(opml.utf8)) { completed, total in
            progress.calls.append((completed, total))
        }

        #expect(summary.alreadySubscribed.count == 1)
        #expect(summary.alreadySubscribed.first?.feedURL.absoluteString == "http://www.existing.example.com/feed")
        #expect(summary.succeeded.count == 1)
        #expect(summary.succeeded.first?.title == "Fresh Show")
        #expect(summary.failed.count == 1)
        #expect(summary.failed.first?.title == "Broken Show")
        #expect(summary.failed.first?.reason.contains("HTTP 500") == true)
        #expect(summary.totalAttempted == 2, "excludes the already-subscribed skip")

        let completedSeq = progress.calls.map(\.0)
        let allTotalsTwo = progress.calls.allSatisfy { $0.1 == 2 }
        #expect(completedSeq == [1, 2], "progress fires once per attempt, monotonically")
        #expect(allTotalsTwo)
    }

    @Test("intra-file duplicates collapse to a single subscribe")
    func collapsesIntraFileDuplicates() async throws {
        let bed = try await makeBed()
        let rss = try rssData()
        bed.feedMock.handler = { request in
            Self.ok(request.url ?? URL(string: "https://x.example.com")!, rss)
        }
        let opml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <body>
            <outline type="rss" text="Dup A" xmlUrl="https://dup.example.com/feed"/>
            <outline type="rss" text="Dup B" xmlUrl="http://www.dup.example.com/feed/"/>
          </body>
        </opml>
        """
        let summary = try await bed.service.importOPML(data: Data(opml.utf8))
        #expect(summary.succeeded.count == 1, "the www./http variant is an intra-file dupe, kept first")
        #expect(summary.totalAttempted == 1)
    }

    @Test("a cancelled import returns the summary-so-far without throwing")
    func cancellationReturnsPartial() async throws {
        let bed = try await makeBed()
        let rss = try rssData()
        bed.feedMock.handler = { request in
            Self.ok(request.url ?? URL(string: "https://x.example.com")!, rss)
        }
        let opml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <body>
            <outline type="rss" text="One" xmlUrl="https://one.example.com/feed"/>
            <outline type="rss" text="Two" xmlUrl="https://two.example.com/feed"/>
          </body>
        </opml>
        """
        let data = Data(opml.utf8)
        let task = Task { try await bed.service.importOPML(data: data) }
        task.cancel()
        let summary = try await task.value
        #expect(summary.succeeded.isEmpty, "cancelled before the subscribe loop ran")
        #expect(summary.failed.isEmpty)
    }
}
