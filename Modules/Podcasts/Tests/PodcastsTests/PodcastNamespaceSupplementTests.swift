import Foundation
import Testing
@testable import Podcasts

private func loadFixture(_ name: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
    )
    return try Data(contentsOf: url)
}

@Suite("PodcastNamespaceSupplement")
struct PodcastNamespaceSupplementTests {
    @Test("Extracts channel funding url + label and per-item chapters keyed by guid")
    func extractsFundingAndChapters() throws {
        let data = try loadFixture("rss-podcast-namespace.xml")
        let result = PodcastNamespaceSupplement().extract(from: data)
        #expect(result.fundingURL == URL(string: "https://example.com/support"))
        #expect(result.fundingText == "Support the show")
        #expect(result.chaptersByGUID["guid-ep1"] == URL(string: "https://example.com/ep1-chapters.json"))
        #expect(result.chaptersByGUID["guid-ep2"] == URL(string: "https://example.com/ep2-chapters.json"))
        // Item three has no guid: keyed by enclosure URL, matching FeedParser.
        #expect(
            result.chaptersByGUID["https://example.com/ep3.mp3"]
                == URL(string: "https://example.com/ep3-chapters.json")
        )
    }

    @Test("Junk bytes yield an empty result and never throw")
    func junkBytesAreNonFatal() {
        let junk = Data([0x00, 0x01, 0xFF, 0xFE])
        let result = PodcastNamespaceSupplement().extract(from: junk)
        #expect(result.fundingURL == nil)
        #expect(result.fundingText == nil)
        #expect(result.chaptersByGUID.isEmpty)
    }

    @Test("Well-formed feed with unusable podcast tags yields no extras")
    func garbageTagsYieldNothing() throws {
        let data = try loadFixture("rss-namespace-garbage.xml")
        let result = PodcastNamespaceSupplement().extract(from: data)
        #expect(result.fundingURL == nil) // ftp scheme rejected
        #expect(result.fundingText == nil) // empty element text
        #expect(result.chaptersByGUID.isEmpty) // javascript scheme rejected
    }
}
