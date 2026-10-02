import Foundation
import Persistence
import Testing
@testable import Podcasts

// The shared `fixture(named:)`, `sourceURL` and `parser` live in `FeedParserTests.swift`.

// MARK: - itunes:type (show_type)

@Suite("FeedParser - itunes:type")
struct FeedParserShowTypeTests {
    /// Minimal RSS with an optional `itunes:type` element.
    private func rss(itunesType: String?) -> Data {
        let typeLine = itunesType.map { "<itunes:type>\($0)</itunes:type>" } ?? ""
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
          <channel>
            <title>Type Test</title>
            \(typeLine)
            <item>
              <title>Ep</title>
              <enclosure url="https://example.com/a.mp3" type="audio/mpeg" length="1"/>
              <guid>g1</guid>
            </item>
          </channel>
        </rss>
        """
        return Data(xml.utf8)
    }

    @Test("serial and episodic parse into showType")
    func parsesKnownTypes() throws {
        #expect(try parser.parse(self.rss(itunesType: "serial"), sourceURL: sourceURL).showType == "serial")
        #expect(try parser.parse(self.rss(itunesType: "episodic"), sourceURL: sourceURL).showType == "episodic")
    }

    @Test("show type is normalized (trim + lowercase)")
    func normalizes() throws {
        #expect(try parser.parse(self.rss(itunesType: "  SERIAL "), sourceURL: sourceURL).showType == "serial")
    }

    @Test("missing or unrecognized itunes:type yields nil")
    func unknownYieldsNil() throws {
        #expect(try parser.parse(self.rss(itunesType: nil), sourceURL: sourceURL).showType == nil)
        #expect(try parser.parse(self.rss(itunesType: "weekly"), sourceURL: sourceURL).showType == nil)
    }

    @Test("Atom feeds have nil showType")
    func atomYieldsNil() throws {
        let feed = try parser.parse(fixture(named: "atom-full.xml"), sourceURL: sourceURL)
        #expect(feed.showType == nil)
    }

    @Test("toPodcast maps show_type and leaves the per-show overrides nil")
    func toPodcastMapsShowTypeOnly() throws {
        let feed = try parser.parse(self.rss(itunesType: "serial"), sourceURL: sourceURL)
        let podcast = feed.toPodcast(feedURL: sourceURL, now: Date(timeIntervalSince1970: 0))
        #expect(podcast.showType == "serial")
        #expect(podcast.episodeSort == nil, "default sort is derived, not seeded")
        #expect(podcast.playbackSpeed == nil)
        #expect(podcast.retentionLimit == nil)
    }
}
