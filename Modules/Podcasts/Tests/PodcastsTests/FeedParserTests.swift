import Foundation
import Persistence
import Testing
@testable import Podcasts

// MARK: - Helper

// Shared with `FeedParserShowTypeTests.swift`.

func fixture(named name: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"),
        "Fixture not found: \(name)"
    )
    return try Data(contentsOf: url)
}

let sourceURL = URL(string: "https://example.com/feed")!
let parser = FeedParser()

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
        let ep1 = try #require(feed.episodes.first { $0.title == "Atom Episode One" })
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

    @Test("RSS 1.0 (RDF) feed throws notAFeed, since the format has no enclosures")
    func rdfFeedThrowsNotAFeed() throws {
        let data = try fixture(named: "rss-rdf.xml")
        do {
            _ = try parser.parse(data, sourceURL: sourceURL)
            Issue.record("expected PodcastsError.notAFeed")
        } catch let PodcastsError.notAFeed(url) {
            #expect(url == sourceURL)
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
        let ep1 = try #require(feed.episodes.first { $0.guid == "guid-ep1" })
        let ep2 = try #require(feed.episodes.first { $0.guid == "guid-ep2" })
        #expect(ep1.chaptersURL == URL(string: "https://example.com/ep1-chapters.json"))
        #expect(ep2.chaptersURL == URL(string: "https://example.com/ep2-chapters.json"))
    }

    @Test("chapters fall back to the enclosure-URL key when the item has no guid")
    func chaptersGuidFallback() throws {
        let data = try fixture(named: "rss-podcast-namespace.xml")
        let feed = try parser.parse(data, sourceURL: sourceURL)
        let ep3 = try #require(feed.episodes.first { $0.guid == "https://example.com/ep3.mp3" })
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
        <?xml-stylesheet type="text/xsl" media="screen" \
        href="/~files/feed-premium-very-long-stylesheet-path-to-push-the-root-well-past-128-bytes.xsl"?>
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

// MARK: - pubDate spellings

/// FeedKit throws on a `pubDate` it cannot read. 10.9.0 could not read the
/// spellings below; 10.9.4 reads them. These cases pin that floor: `FeedDateRepair`
/// keeps the feed alive either way, but only FeedKit gives these the exact instant.
@Suite("FeedParser - pubDate spellings")
struct FeedParserPubDateTests {
    private func rss(pubDate: String) -> Data {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0">
          <channel>
            <title>Date Test</title>
            <item>
              <title>Ep</title>
              <enclosure url="https://example.com/a.mp3" type="audio/mpeg" length="1"/>
              <guid>g1</guid>
              <pubDate>\(pubDate)</pubDate>
            </item>
          </channel>
        </rss>
        """
        return Data(xml.utf8)
    }

    private func publishedAt(_ pubDate: String) throws -> Date? {
        try parser.parse(self.rss(pubDate: pubDate), sourceURL: sourceURL).episodes.first?.publishedAt
    }

    @Test(
        "A zone abbreviation outside RFC 822, or no zone, still parses the feed",
        arguments: [
            "Mon, 01 Jan 2024 10:00:00 BST",
            "Mon, 01 Jan 2024 10:00:00 CEST",
            "Mon, 01 Jan 2024 10:00:00 AEST",
            "Mon, 01 Jan 2024 10:00:00",
        ]
    )
    func unusualZoneParses(pubDate: String) throws {
        // Only the day is asserted: FeedKit reads some of these zones loosely
        // (BST as Bangladesh time, CEST as midnight). The contract here is that
        // the feed parses and the episode lands on the right day.
        let date = try #require(try self.publishedAt(pubDate))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        let day = utc.dateComponents([.year, .month, .day], from: date)
        #expect(day.year == 2024 && day.month == 1 && day.day == 1)
    }

    @Test("A missing space after the weekday comma reads the exact instant")
    func weekdayWithoutSpace() throws {
        #expect(try self.publishedAt("Mon,01 Jan 2024 10:00:00 GMT") == Date(timeIntervalSince1970: 1_704_103_200))
    }

    @Test("A two-digit year reads as this century, not the first")
    func twoDigitYear() throws {
        #expect(try self.publishedAt("Mon, 01 Jan 24 10:00:00 GMT") == Date(timeIntervalSince1970: 1_704_103_200))
    }
}

// MARK: - Unreadable dates (#597)

/// A date FeedKit cannot read must cost one episode its date at most, never
/// the whole feed.
@Suite("FeedParser - unreadable dates")
struct FeedParserUnreadableDateTests {
    /// Three episodes: a good date, `badDate`, and a good date.
    private func rss(badDate: String, prolog: String = "") -> Data {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        \(prolog)<rss version="2.0" xmlns:podcast="https://podcastindex.org/namespace/1.0">
          <channel>
            <title>Date Test</title>
            <lastBuildDate>yesterday</lastBuildDate>
            <item>
              <title>Good 1</title>
              <enclosure url="https://example.com/a.mp3" type="audio/mpeg" length="1"/>
              <guid>g1</guid>
              <pubDate>Mon, 01 Jan 2024 10:00:00 GMT</pubDate>
            </item>
            <item>
              <title>Bad</title>
              <enclosure url="https://example.com/b.mp3" type="audio/mpeg" length="1"/>
              <guid>g2</guid>
              <pubDate>\(badDate)</pubDate>
              <podcast:chapters url="https://example.com/b.json" type="application/json"/>
            </item>
            <item>
              <title>Good 2</title>
              <enclosure url="https://example.com/c.mp3" type="audio/mpeg" length="1"/>
              <guid>g3</guid>
              <pubDate>Wed, 01 Jan 2025 10:00:00 BST</pubDate>
            </item>
          </channel>
        </rss>
        """
        return Data(xml.utf8)
    }

    private func episode(_ guid: String, in feed: ParsedFeed) throws -> ParsedEpisode {
        try #require(feed.episodes.first { $0.guid == guid })
    }

    @Test(
        "A date in a shape we know is rewritten, and the episode keeps the right day",
        arguments: [
            ("2024-06-01", 1_717_200_000.0),
            ("01 Sept 2024", 1_725_148_800.0),
            ("1 September 2024", 1_725_148_800.0),
            ("Sun, 01 Sept 2024", 1_725_148_800.0),
            ("September 1, 2024", 1_725_148_800.0),
            ("<![CDATA[ 2024-06-01 ]]>", 1_717_200_000.0),
            ("Sun, 01 Sept 2024 10:00:00 GMT", 1_725_184_800.0),
        ]
    )
    func knownShapeIsRewritten(badDate: String, expected: Double) throws {
        let feed = try parser.parse(self.rss(badDate: badDate), sourceURL: sourceURL)
        #expect(feed.episodes.count == 3)
        #expect(try self.episode("g2", in: feed).publishedAt == Date(timeIntervalSince1970: expected))
    }

    @Test(
        "A date nobody can read costs that episode its date, and nothing else",
        arguments: ["last Tuesday", "01 Sep 2024 at teatime", "32/13/2024", "2024-13-45"]
    )
    func unreadableDateIsDropped(badDate: String) throws {
        let feed = try parser.parse(self.rss(badDate: badDate), sourceURL: sourceURL)
        #expect(feed.episodes.count == 3)
        let bad = try self.episode("g2", in: feed)
        #expect(bad.publishedAt == nil)
        #expect(bad.title == "Bad")
        #expect(bad.audioURL == URL(string: "https://example.com/b.mp3"))
        // The supplement reads the original bytes, so its values still attach.
        #expect(bad.chaptersURL == URL(string: "https://example.com/b.json"))
        // Dated episodes sort newest-first; the undated one goes last.
        #expect(feed.episodes.map(\.guid) == ["g3", "g1", "g2"])
    }

    @Test("The dates FeedKit reads are left exactly as the feed wrote them")
    func readableDatesAreUntouched() throws {
        let feed = try parser.parse(self.rss(badDate: "last Tuesday"), sourceURL: sourceURL)
        #expect(try self.episode("g1", in: feed).publishedAt == Date(timeIntervalSince1970: 1_704_103_200))
        // BST is one of the loose zones FeedKit reads; the repair must not drop it.
        #expect(try self.episode("g3", in: feed).publishedAt != nil)
    }

    @Test("A stylesheet prolog and a bad date in one feed both recover")
    func prologAndBadDate() throws {
        let padding = String(repeating: " ", count: 300)
        let prolog = "<?xml-stylesheet type=\"text/xsl\" href=\"style.xsl\"?>\(padding)\n"
        let feed = try parser.parse(self.rss(badDate: "last Tuesday", prolog: prolog), sourceURL: sourceURL)
        #expect(feed.episodes.count == 3)
    }

    @Test("An unreadable Atom date does not fail the feed either")
    func atomBadDate() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Atom Date Test</title>
          <updated>whenever</updated>
          <entry>
            <id>a1</id>
            <title>Entry</title>
            <published>soon</published>
            <updated>2024-06-01</updated>
            <link rel="enclosure" type="audio/mpeg" href="https://example.com/a.mp3"/>
          </entry>
        </feed>
        """
        let feed = try parser.parse(Data(xml.utf8), sourceURL: sourceURL)
        // `published` is dropped, so the episode falls back to the rewritten `updated`.
        #expect(feed.episodes.first?.publishedAt == Date(timeIntervalSince1970: 1_717_200_000))
    }

    @Test("Bytes outside the dates survive the repair in a non-UTF-8 feed")
    func latin1FeedRoundTrips() throws {
        let xml = """
        <?xml version="1.0" encoding="ISO-8859-1"?>
        <rss version="2.0">
          <channel>
            <title>Caf\u{E9} Hour</title>
            <item>
              <title>Na\u{EF}ve</title>
              <enclosure url="https://example.com/a.mp3" type="audio/mpeg" length="1"/>
              <guid>g1</guid>
              <pubDate>2024-06-01</pubDate>
            </item>
          </channel>
        </rss>
        """
        let feed = try parser.parse(#require(xml.data(using: .isoLatin1)), sourceURL: sourceURL)
        #expect(feed.title == "Caf\u{E9} Hour")
        #expect(feed.episodes.first?.title == "Na\u{EF}ve")
        #expect(feed.episodes.first?.publishedAt == Date(timeIntervalSince1970: 1_717_200_000))
    }

    @Test("A feed that fails for another reason is not repaired")
    func otherFailureIsLeftAlone() throws {
        let data = try fixture(named: "rss-full.xml")
        #expect(FeedDateRepair().repair(data) == nil)
        #expect(FeedDateRepair().repair(Data("<html><body>nope</body></html>".utf8)) == nil)
    }

    @Test("The repair counts what it rewrote and what it dropped")
    func outcomeCounts() throws {
        let outcome = try #require(FeedDateRepair().repair(self.rss(badDate: "2024-06-01")))
        // `lastBuildDate` ("yesterday") is dropped; the bad pubDate is rewritten.
        #expect(outcome.rewritten == 1)
        #expect(outcome.dropped == 1)
        let text = try #require(String(bytes: outcome.data, encoding: .utf8))
        #expect(text.contains("<pubDate>2024-06-01T00:00:00Z</pubDate>"))
        #expect(!text.contains("lastBuildDate"))
        #expect(text.contains("<pubDate>Wed, 01 Jan 2025 10:00:00 BST</pubDate>"))
    }
}
