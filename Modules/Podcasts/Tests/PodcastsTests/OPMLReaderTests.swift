import Foundation
import Testing
@testable import Podcasts

private func loadOPML(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Suite("OPMLReader")
struct OPMLReaderTests {
    @Test("flat list: feed URLs and title precedence (title -> text -> host)")
    func flatList() throws {
        let entries = try OPMLReader.parse(data: loadOPML("opml-flat.opml"))
        #expect(entries.map(\.feedURL.absoluteString) == [
            "https://example.com/one/feed.xml",
            "https://feeds.example.org/two",
            "https://three.example.net/feed",
        ])
        // title wins over text; text used when no title; host fallback when neither.
        #expect(entries.map(\.title) == ["Show One", "Show Two", "three.example.net"])
        #expect(entries[0].htmlURL == URL(string: "https://example.com/one"))
        #expect(entries[1].htmlURL == nil)
    }

    @Test("nested groups are flattened to the full feed list at any depth")
    func nestedFlattening() throws {
        let entries = try OPMLReader.parse(data: loadOPML("opml-nested.opml"))
        #expect(entries.map(\.feedURL.absoluteString) == [
            "https://tech.example.com/a",
            "https://tech.example.com/b",
            "https://standalone.example.com/feed",
        ])
    }

    @Test("outlines with no/invalid xmlUrl are skipped without throwing")
    func skipsInvalidOutlines() throws {
        // The reader keeps both http(s) entries (incl. the www. dupe); intra-file
        // dedupe is an import-time concern, not a reader concern.
        let entries = try OPMLReader.parse(data: loadOPML("opml-missing-xmlurl.opml"))
        #expect(entries.map(\.feedURL.absoluteString) == [
            "https://valid.example.com/feed",
            "https://www.valid.example.com/feed/",
        ])
    }

    @Test("malformed XML throws parseFailed, not a silent empty list")
    func malformedThrows() {
        let truncated = Data("<?xml version=\"1.0\"?><opml version=\"2.0\"><body><outline xmlUrl=\"https://x".utf8)
        #expect(throws: PodcastsError.self) {
            _ = try OPMLReader.parse(data: truncated)
        }
    }
}
