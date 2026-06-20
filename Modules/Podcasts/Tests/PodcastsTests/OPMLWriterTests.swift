import Foundation
import Persistence
import Testing
@testable import Podcasts

@Suite("OPMLWriter")
struct OPMLWriterTests {
    private let pinnedNow = Date(timeIntervalSince1970: 1_700_000_000)

    private func makePodcast(feedURL: String, title: String, link: String? = nil) -> Podcast {
        var podcast = Podcast(feedURL: feedURL, title: title, addedAt: 0)
        podcast.link = link
        return podcast
    }

    @Test("emits OPML 2.0 with a fixed head title and a pinned RFC 822 dateCreated")
    func headMetadata() {
        let opml = OPMLWriter.write([], now: self.pinnedNow)
        #expect(opml.contains(#"<opml version="2.0">"#))
        #expect(opml.contains("<title>Bocan Podcast Subscriptions</title>"))
        #expect(opml.contains("<dateCreated>"))
        #expect(opml.contains("14 Nov 2023"))
        #expect(opml.contains("GMT</dateCreated>"))
    }

    @Test("round-trips feed URLs, titles, and htmlUrls through the reader")
    func roundTrip() throws {
        let podcasts = [
            self.makePodcast(feedURL: "https://a.example.com/feed", title: "Alpha", link: "https://a.example.com"),
            self.makePodcast(feedURL: "https://b.example.com/feed", title: "Beta"),
        ]
        let opml = OPMLWriter.write(podcasts, now: self.pinnedNow)
        let entries = try OPMLReader.parse(data: Data(opml.utf8))

        #expect(entries.map(\.feedURL.absoluteString) == ["https://a.example.com/feed", "https://b.example.com/feed"])
        #expect(entries.map(\.title) == ["Alpha", "Beta"])
        #expect(entries[0].htmlURL == URL(string: "https://a.example.com"))
        #expect(entries[1].htmlURL == nil)
    }

    @Test("XML-special characters in a title are escaped and re-read intact")
    func escapesAndRoundTripsSpecialChars() throws {
        let title = "Alpha & Beta <Show> \"Quoted\" 'Apos'"
        let opml = OPMLWriter.write([self.makePodcast(feedURL: "https://x.example.com/feed", title: title)], now: self.pinnedNow)

        #expect(opml.contains("&amp;"))
        #expect(opml.contains("&lt;"))
        #expect(opml.contains("&gt;"))
        #expect(opml.contains("&quot;"))
        #expect(!opml.contains("& Beta"), "raw ampersand must be escaped")

        let entries = try OPMLReader.parse(data: Data(opml.utf8))
        #expect(entries.first?.title == title)
    }
}
