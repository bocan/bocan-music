import Foundation
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
