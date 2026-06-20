import Foundation
import Persistence
import Testing
@testable import Podcasts

// MARK: - Helper

private func fixture(named name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"),
          let data = try? Data(contentsOf: url) else {
        throw PodcastsError.parseFailed(
            url: URL(string: "test://\(name)")!,
            reason: "Fixture not found: \(name)"
        )
    }
    return data
}

private let sourceURL = URL(string: "https://example.com/feed")!
private let parser = FeedParser()

@Suite("FeedParser - RSS full fixture")
struct FeedParserRSSFullTests {
    @Test("Headline regression: RSS full fixture parses to the expected channel metadata")
    func rssFullChannelMetadata() throws {
        let data = try fixture(named: "rss-full.xml")
        let feed = try parser.parse(data, sourceURL: sourceURL)
        #expect(feed.title == "Full Feature Podcast")
        #expect(feed.author == "Jane Smith")
        #expect(feed.description == "A podcast with every field populated.")
        #expect(feed.language == "en-us")
        #expect(feed.explicit == true)
        #expect(feed.copyright == "2024 Example Inc.")
        #expect(feed.ownerName == "Jane Smith")
        #expect(feed.ownerEmail == "jane@example.com")
        #expect(feed.artworkURL == URL(string: "https://example.com/artwork.jpg"))
        #expect(feed.link == URL(string: "https://example.com/podcast"))
    }

    @Test("RSS full fixture: categories are deduplicated and sorted")
    func rssFullCategories() throws {
        let data = try fixture(named: "rss-full.xml")
        let feed = try parser.parse(data, sourceURL: sourceURL)
        #expect(feed.categories.contains("Technology"))
        #expect(feed.categories.contains("Software How-To"))
        #expect(feed.categories.contains("Science"))
        #expect(feed.categories == feed.categories.sorted())
    }

    @Test("RSS full fixture: two episodes are present and sorted newest-first")
    func rssFullEpisodeCountAndOrder() throws {
        let data = try fixture(named: "rss-full.xml")
        let feed = try parser.parse(data, sourceURL: sourceURL)
        #expect(feed.episodes.count == 2)
        // Episode 2 published June 17 should come before Episode 1 (June 10).
        #expect(feed.episodes[0].episodeNumber == 2)
        #expect(feed.episodes[1].episodeNumber == 1)
    }

    @Test("RSS full fixture: episode 1 fields are fully populated")
    func rssFullEpisode1Fields() throws {
        let data = try fixture(named: "rss-full.xml")
        let feed = try parser.parse(data, sourceURL: sourceURL)
        let ep = feed.episodes[1]
        #expect(ep.guid == "https://example.com/episodes/1")
        #expect(ep.title == "Episode 1: The Pilot")
        #expect(ep.subtitle == "Intro episode")
        #expect(ep.descriptionHTML?.contains("Rich HTML description") == true)
        #expect(ep.audioURL == URL(string: "https://example.com/ep1.mp3"))
        #expect(ep.audioMIME == "audio/mpeg")
        #expect(ep.audioByteLength == 12_345_678)
        #expect(ep.duration == 3723)
        #expect(ep.season == 1)
        #expect(ep.episodeNumber == 1)
        #expect(ep.episodeType == "full")
        #expect(ep.explicit == false)
        #expect(ep.artworkURL == URL(string: "https://example.com/ep1-art.jpg"))
    }

    @Test("RSS full fixture: podcast:guid is parsed into podcastGUID")
    func rssFullPodcastGUID() throws {
        let data = try fixture(named: "rss-full.xml")
        let feed = try parser.parse(data, sourceURL: sourceURL)
        #expect(feed.podcastGUID == "ead4c236-bf58-58c6-a2c6-a6b28d128cb6")
    }

    @Test("RSS full fixture: episode transcript prefers VTT over plain text")
    func rssFullEpisodeTranscript() throws {
        let data = try fixture(named: "rss-full.xml")
        let feed = try parser.parse(data, sourceURL: sourceURL)
        let ep1 = feed.episodes[1]
        #expect(ep1.transcriptURL == URL(string: "https://example.com/ep1-transcript.vtt"))
    }

    @Test("RSS full fixture: episode artwork falls back to a Media RSS thumbnail")
    func rssFullEpisodeMediaThumbnailFallback() throws {
        let data = try fixture(named: "rss-full.xml")
        let feed = try parser.parse(data, sourceURL: sourceURL)
        // Episode 2 has no itunes:image, only a media:thumbnail.
        let ep2 = feed.episodes[0]
        #expect(ep2.artworkURL == URL(string: "https://example.com/ep2-media.jpg"))
    }
}

@Suite("FeedParser - RSS minimal fixture")
struct FeedParserRSSMinimalTests {
    @Test("Minimal RSS feed parses without crashing")
    func rssMinimalParses() throws {
        let data = try fixture(named: "rss-minimal.xml")
        let feed = try parser.parse(data, sourceURL: sourceURL)
        #expect(feed.title == "Minimal Podcast")
        #expect(feed.episodes.count == 1)
    }

    @Test("Minimal RSS episode GUID falls back to enclosure URL")
    func rssMinimalGUIDFallback() throws {
        let data = try fixture(named: "rss-minimal.xml")
        let feed = try parser.parse(data, sourceURL: sourceURL)
        #expect(feed.episodes[0].guid == "https://minimal.example.com/ep.mp3")
    }
}

@Suite("FeedParser - video skip fixture")
struct FeedParserVideoSkipTests {
    @Test("Video enclosures are skipped; audio enclosures are kept")
    func videoEnclosuresSkipped() throws {
        let data = try fixture(named: "rss-video-skip.xml")
        let feed = try parser.parse(data, sourceURL: sourceURL)
        #expect(feed.episodes.count == 1)
        #expect(feed.episodes[0].audioURL.absoluteString.hasSuffix(".mp3"))
    }
}

@Suite("FeedParser - Atom fixture")
struct FeedParserAtomTests {
    @Test("Atom full fixture: channel metadata extracted correctly")
    func atomChannelMetadata() throws {
        let data = try fixture(named: "atom-full.xml")
        let feed = try parser.parse(data, sourceURL: sourceURL)
        #expect(feed.title == "Atom Podcast")
        #expect(feed.description == "An Atom-format podcast feed.")
        #expect(feed.author == "Atom Author")
        #expect(feed.ownerEmail == "author@atom.example.com")
        #expect(feed.copyright == "2024 Atom Publishing Inc.")
        #expect(feed.artworkURL == URL(string: "https://atom.example.com/logo.png"))
    }

    @Test("Atom full fixture: two episodes, newest first")
    func atomEpisodeOrder() throws {
        let data = try fixture(named: "atom-full.xml")
        let feed = try parser.parse(data, sourceURL: sourceURL)
        #expect(feed.episodes.count == 2)
        #expect(feed.episodes[0].title == "Atom Episode Two")
        #expect(feed.episodes[1].title == "Atom Episode One")
    }

    @Test("Atom entry content is preferred over summary for descriptionHTML")
    func atomContentPreferredOverSummary() throws {
        let data = try fixture(named: "atom-full.xml")
        let feed = try parser.parse(data, sourceURL: sourceURL)
        let ep1 = try #require(feed.episodes.first(where: { $0.title == "Atom Episode One" }))
        #expect(ep1.descriptionHTML?.contains("Full HTML content") == true)
    }
}

@Suite("FeedParser - invalid inputs")
struct FeedParserInvalidTests {
    @Test("Non-feed XML data throws notAFeed error")
    func notAFeedXMLThrows() throws {
        let data = try fixture(named: "not-a-feed.xml")
        #expect(throws: PodcastsError.self) {
            try parser.parse(data, sourceURL: sourceURL)
        }
    }

    @Test("Garbage bytes throw parseFailed error")
    func garbageBytesThrow() throws {
        let junk = Data([0x00, 0x01, 0xFF, 0xFE])
        #expect(throws: PodcastsError.self) {
            try parser.parse(junk, sourceURL: sourceURL)
        }
    }
}

@Suite("FeedParser - podcast namespace supplement")
struct FeedParserPodcastNamespaceTests {
    @Test("podcast:funding url and label populate the feed")
    func fundingPopulated() throws {
        let data = try fixture(named: "rss-podcast-namespace.xml")
        let feed = try parser.parse(data, sourceURL: sourceURL)
        #expect(feed.fundingURL == URL(string: "https://example.com/support"))
        #expect(feed.fundingText == "Support the show")
    }

    @Test("podcast:chapters populate each episode by guid, regardless of tag order")
    func chaptersByGuid() throws {
        let data = try fixture(named: "rss-podcast-namespace.xml")
        let feed = try parser.parse(data, sourceURL: sourceURL)
        let ep1 = try #require(feed.episodes.first(where: { $0.guid == "guid-ep1" }))
        let ep2 = try #require(feed.episodes.first(where: { $0.guid == "guid-ep2" }))
        #expect(ep1.chaptersURL == URL(string: "https://example.com/ep1-chapters.json"))
        #expect(ep2.chaptersURL == URL(string: "https://example.com/ep2-chapters.json"))
    }

    @Test("chapters fall back to the enclosure-URL key when the item has no guid")
    func chaptersGuidFallback() throws {
        let data = try fixture(named: "rss-podcast-namespace.xml")
        let feed = try parser.parse(data, sourceURL: sourceURL)
        let ep3 = try #require(feed.episodes.first(where: { $0.guid == "https://example.com/ep3.mp3" }))
        #expect(ep3.chaptersURL == URL(string: "https://example.com/ep3-chapters.json"))
    }

    @Test("Unusable podcast tags leave funding and chapters nil without failing the parse")
    func garbageTagsAreNonFatal() throws {
        let data = try fixture(named: "rss-namespace-garbage.xml")
        let feed = try parser.parse(data, sourceURL: sourceURL)
        #expect(feed.title == "Garbage Namespace Podcast")
        #expect(feed.fundingURL == nil)
        #expect(feed.fundingText == nil)
        let noChapters = feed.episodes.allSatisfy { $0.chaptersURL == nil }
        #expect(noChapters)
    }
}

// MARK: - xml-stylesheet prolog recovery

@Suite("FeedParser - xml-stylesheet prolog")
struct FeedParserStylesheetPrologTests {
    @Test("RSS with a long xml-stylesheet PI before the root still parses")
    func parsesPastStylesheetPI() throws {
        // The stylesheet PI pushes <rss past FeedKit's 128-byte sniff window, so the
        // first Feed(data:) fails and the prolog-strip fallback must recover it.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <?xml-stylesheet type="text/xsl" media="screen" href="/~files/feed-premium-very-long-stylesheet-path-to-push-the-root-well-past-128-bytes.xsl"?>
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
          <channel>
            <title>Stylesheet Feed</title>
            <item>
              <title>Ep1</title>
              <enclosure url="https://example.com/a.mp3" type="audio/mpeg" length="1"/>
              <guid>g1</guid>
            </item>
          </channel>
        </rss>
        """
        let data = Data(xml.utf8)
        // Guard: the root really is beyond FeedKit's 128-byte window for this fixture.
        let rootOffset = data.range(of: Data("<rss".utf8))?.lowerBound ?? 0
        #expect(rootOffset > 128, "fixture must reproduce the sniff-window failure")

        let feed = try parser.parse(data, sourceURL: sourceURL)
        #expect(feed.title == "Stylesheet Feed")
        #expect(feed.episodes.count == 1)
    }
}

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
