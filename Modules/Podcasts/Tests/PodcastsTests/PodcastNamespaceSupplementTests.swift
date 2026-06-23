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

    @Test("Extracts channel-level and item-level podcast:person credits")
    func extractsPersons() throws {
        let data = try loadFixture("rss-podcast-namespace.xml")
        let result = PodcastNamespaceSupplement().extract(from: data)

        #expect(result.channelPersons.count == 2)
        let john = result.channelPersons.first
        #expect(john?.name == "John Smith")
        #expect(john?.role == "host")
        #expect(john?.imageURL == "https://example.com/john.jpg")
        #expect(john?.href == "https://example.com/john")
        let jane = result.channelPersons.last
        #expect(jane?.name == "Jane Doe")
        #expect(jane?.role == "Producer") // preserved verbatim (spec is case-insensitive)
        #expect(jane?.group == "production")

        // Item-level person keyed by guid, not leaking into the channel list.
        let alice = result.personsByGUID["guid-ep1"]?.first
        #expect(alice?.name == "Alice Brown")
        #expect(alice?.role == "guest")
        #expect(result.personsByGUID["guid-ep2"] == nil)
    }

    @Test("Extracts channel-level podcast:podroll recommendations, rejecting bad URLs")
    func extractsPodroll() throws {
        let data = try loadFixture("rss-podcast-namespace.xml")
        let result = PodcastNamespaceSupplement().extract(from: data)

        // The ftp remoteItem is dropped; the two web feeds remain in order.
        #expect(result.podroll.count == 2)
        #expect(result.podroll.first?.feedURL == "https://example.com/recommended-a.xml")
        #expect(result.podroll.first?.feedGUID == "guid-a")
        #expect(result.podroll.first?.title == nil)
        #expect(result.podroll.last?.feedURL == "https://example.com/recommended-b.xml")
        #expect(result.podroll.last?.title == "Recommended B")
    }

    @Test("Ignores remoteItem outside a podroll (e.g. valueTimeSplit)")
    func ignoresRemoteItemOutsidePodroll() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:podcast="https://podcastindex.org/namespace/1.0">
          <channel>
            <title>VTS</title>
            <podcast:value type="lightning" method="keysend">
              <podcast:valueTimeSplit startTime="60" duration="30">
                <podcast:remoteItem feedUrl="https://example.com/not-a-recommendation.xml"/>
              </podcast:valueTimeSplit>
            </podcast:value>
          </channel>
        </rss>
        """
        let result = PodcastNamespaceSupplement().extract(from: Data(xml.utf8))
        #expect(result.podroll.isEmpty)
    }

    @Test("Drops nameless persons and rejects non-web img/href")
    func personEdgeCases() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:podcast="https://podcastindex.org/namespace/1.0">
          <channel>
            <title>Edge</title>
            <podcast:person img="ftp://example.com/x.jpg" href="javascript:alert(1)">Real Name</podcast:person>
            <podcast:person>   </podcast:person>
          </channel>
        </rss>
        """
        let result = PodcastNamespaceSupplement().extract(from: Data(xml.utf8))
        #expect(result.channelPersons.count == 1) // blank-name person dropped
        #expect(result.channelPersons.first?.name == "Real Name")
        #expect(result.channelPersons.first?.imageURL == nil) // ftp rejected
        #expect(result.channelPersons.first?.href == nil) // javascript rejected
    }

    @Test("Accepts the legacy GitHub-docs namespace URI bound to the prefix")
    func acceptsGitHubNamespaceURI() {
        // Podcast Index's own canonical pc20.xml binds the prefix to this older URL,
        // not the spec's podcastindex.org/namespace/1.0. Both must be honoured.
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:podcast="https://github.com/Podcastindex-org/podcast-namespace/blob/main/docs/1.0.md">
          <channel>
            <title>Legacy NS</title>
            <podcast:funding url="https://example.com/support">Value 4 Value</podcast:funding>
            <podcast:person href="https://example.com/host" role="host">Host Person</podcast:person>
            <item>
              <guid>guid-ep1</guid>
              <podcast:person role="guest">Guest Person</podcast:person>
            </item>
          </channel>
        </rss>
        """
        let result = PodcastNamespaceSupplement().extract(from: Data(xml.utf8))
        #expect(result.fundingURL == URL(string: "https://example.com/support"))
        #expect(result.fundingText == "Value 4 Value")
        #expect(result.channelPersons.first?.name == "Host Person")
        #expect(result.personsByGUID["guid-ep1"]?.first?.name == "Guest Person")
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
