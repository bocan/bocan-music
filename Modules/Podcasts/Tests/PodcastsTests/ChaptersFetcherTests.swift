import Foundation
import Testing
@testable import Podcasts

private func loadFixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Suite("ChaptersFetcher.parse")
struct ChaptersParseTests {
    @Test("Podcasting 2.0 chapters parse, sort by start time, and carry optional fields")
    func parsesAndSorts() throws {
        let chapters = try ChaptersFetcher.parse(loadFixture("chapters-pc20.json"))
        #expect(chapters.count == 3)
        #expect(chapters.map(\.title) == ["Intro", "Sponsor", "Main Topic"])
        #expect(chapters[0].startTime == 0)
        #expect(chapters[1].startTime == 30)
        #expect(chapters[2].startTime == 65)
        #expect(chapters.map(\.id) == [0, 1, 2])
        #expect(chapters[2].imageURL == URL(string: "https://example.com/ch2.jpg"))
        #expect(chapters[2].url == URL(string: "https://example.com/ch2"))
        #expect(chapters[0].imageURL == nil)
    }

    @Test("malformed entries are skipped and extra keys ignored")
    func degradesGracefully() throws {
        let chapters = try ChaptersFetcher.parse(loadFixture("chapters-malformed.json"))
        #expect(chapters.count == 2)
        #expect(chapters[0].title == "Valid one")
        #expect(chapters[0].startTime == 10)
        #expect(chapters[1].title == "")
    }

    @Test("empty chapters array and garbage both yield an empty list")
    func emptyAndGarbage() {
        #expect(ChaptersFetcher.parse(Data("{ \"chapters\": [] }".utf8)).isEmpty)
        #expect(ChaptersFetcher.parse(Data([0x00, 0x01, 0xFF])).isEmpty)
    }
}

@Suite("Chapter.current(at:)")
struct ChapterCurrentTests {
    private let chapters = [
        Chapter(id: 0, startTime: 0, title: "A"),
        Chapter(id: 1, startTime: 30, title: "B"),
        Chapter(id: 2, startTime: 60, title: "C"),
    ]

    @Test("picks the last chapter whose start is at or before the position", arguments: [
        (-5.0, Int?.none),
        (0.0, Int?.some(0)),
        (15.0, Int?.some(0)),
        (30.0, Int?.some(1)),
        (59.9, Int?.some(1)),
        (60.0, Int?.some(2)),
        (9999.0, Int?.some(2)),
    ])
    func current(position: Double, expectedID: Int?) {
        #expect(self.chapters.current(at: position)?.id == expectedID)
    }

    @Test("empty list has no current chapter")
    func empty() {
        #expect([Chapter]().current(at: 10) == nil)
    }
}

@Suite("ChaptersFetcher fetch")
struct ChaptersFetchTests {
    @Test("fetch parses the served body and caches: a second call does not re-fetch")
    func fetchAndCache() async throws {
        let mock = MockHTTPClient()
        var requestCount = 0
        let body = "{ \"chapters\": [ { \"startTime\": 0, \"title\": \"Intro\" } ] }"
        mock.handler = { _ in
            requestCount += 1
            return (Data(body.utf8), HTTPURLResponse(
                url: URL(string: "https://example.com/ch.json")!,
                statusCode: 200, httpVersion: nil, headerFields: nil
            )!)
        }
        let fetcher = ChaptersFetcher(http: mock)
        let url = try #require(URL(string: "https://example.com/ch.json"))
        let first = try await fetcher.chapters(for: url)
        let second = try await fetcher.chapters(for: url)
        #expect(first.count == 1)
        #expect(first.first?.title == "Intro")
        #expect(second.count == 1)
        #expect(requestCount == 1, "second call must hit the in-memory cache")
    }

    @Test("a non-2xx response throws")
    func nonOKThrows() async throws {
        let mock = MockHTTPClient()
        mock.handler = { _ in
            (Data(), HTTPURLResponse(
                url: URL(string: "https://example.com/ch.json")!,
                statusCode: 500, httpVersion: nil, headerFields: nil
            )!)
        }
        let fetcher = ChaptersFetcher(http: mock)
        let url = try #require(URL(string: "https://example.com/ch.json"))
        await #expect(throws: PodcastsError.self) {
            _ = try await fetcher.chapters(for: url)
        }
    }

    @Test("an oversized body throws")
    func oversizeThrows() async throws {
        let mock = MockHTTPClient()
        mock.handler = { _ in
            (Data(count: 2048), HTTPURLResponse(
                url: URL(string: "https://example.com/ch.json")!,
                statusCode: 200, httpVersion: nil, headerFields: nil
            )!)
        }
        let fetcher = ChaptersFetcher(http: mock, maxBytes: 1024)
        let url = try #require(URL(string: "https://example.com/ch.json"))
        await #expect(throws: PodcastsError.self) {
            _ = try await fetcher.chapters(for: url)
        }
    }
}
