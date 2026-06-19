import Foundation
import Testing
@testable import Podcasts

@Suite("FeedURL")
struct FeedURLTests {
    // MARK: - canonicalKey

    @Test("http and https produce the same key")
    func httpAndHttpsSameKey() throws {
        let http = try #require(URL(string: "http://example.com/feed"))
        let https = try #require(URL(string: "https://example.com/feed"))
        #expect(FeedURL.canonicalKey(http) == FeedURL.canonicalKey(https))
    }

    @Test("www-prefixed and bare host produce the same key")
    func wwwDroppedFromKey() throws {
        let www = try #require(URL(string: "https://www.example.com/feed"))
        let bare = try #require(URL(string: "https://example.com/feed"))
        #expect(FeedURL.canonicalKey(www) == FeedURL.canonicalKey(bare))
    }

    @Test("trailing slash is dropped from key")
    func trailingSlashDropped() throws {
        let slashed = try #require(URL(string: "https://example.com/feed/"))
        let clean = try #require(URL(string: "https://example.com/feed"))
        #expect(FeedURL.canonicalKey(slashed) == FeedURL.canonicalKey(clean))
    }

    @Test("fragment is dropped from key")
    func fragmentDropped() throws {
        let withFrag = try #require(URL(string: "https://example.com/feed#top"))
        let noFrag = try #require(URL(string: "https://example.com/feed"))
        #expect(FeedURL.canonicalKey(withFrag) == FeedURL.canonicalKey(noFrag))
    }

    @Test("default port 443 is dropped from key")
    func defaultPortDropped() throws {
        let withPort = try #require(URL(string: "https://example.com:443/feed"))
        let noPort = try #require(URL(string: "https://example.com/feed"))
        #expect(FeedURL.canonicalKey(withPort) == FeedURL.canonicalKey(noPort))
    }

    @Test("default port 80 is dropped from key")
    func defaultPort80Dropped() throws {
        let withPort = try #require(URL(string: "http://example.com:80/feed"))
        let noPort = try #require(URL(string: "http://example.com/feed"))
        #expect(FeedURL.canonicalKey(withPort) == FeedURL.canonicalKey(noPort))
    }

    @Test("non-default port is kept in key")
    func nonDefaultPortKept() throws {
        let custom = try #require(URL(string: "https://example.com:8080/feed"))
        let standard = try #require(URL(string: "https://example.com/feed"))
        #expect(FeedURL.canonicalKey(custom) != FeedURL.canonicalKey(standard))
    }

    @Test("query string is kept in key")
    func queryStringKept() throws {
        let withQuery = try #require(URL(string: "https://example.com/feed?id=42"))
        let noQuery = try #require(URL(string: "https://example.com/feed"))
        #expect(FeedURL.canonicalKey(withQuery) != FeedURL.canonicalKey(noQuery))
    }

    @Test("all canonicalization rules applied together")
    func allRulesApplied() throws {
        let messy = try #require(URL(string: "HTTPS://WWW.EXAMPLE.COM:443/feed/?x=1#top"))
        let key = FeedURL.canonicalKey(messy)
        #expect(key == "example.com/feed?x=1")
    }

    @Test("root path alone does not strip trailing slash")
    func rootPathNotStripped() throws {
        let root = try #require(URL(string: "https://example.com/"))
        let key = FeedURL.canonicalKey(root)
        #expect(key == "example.com/")
    }

    // MARK: - normalizedStorageURL

    @Test("http URL is upgraded to https in storage URL")
    func httpUpgradedToHttps() throws {
        let http = try #require(URL(string: "http://example.com/feed"))
        let stored = FeedURL.normalizedStorageURL(http)
        #expect(stored?.scheme == "https")
    }

    @Test("fragment is removed from storage URL")
    func fragmentRemovedFromStorageURL() throws {
        let url = try #require(URL(string: "https://example.com/feed#top"))
        let stored = FeedURL.normalizedStorageURL(url)
        #expect(stored?.fragment == nil)
    }

    @Test("trailing slash removed from storage URL path")
    func trailingSlashRemovedFromStorageURL() throws {
        let url = try #require(URL(string: "https://example.com/feed/"))
        let stored = FeedURL.normalizedStorageURL(url)
        #expect(stored?.path == "/feed")
    }

    @Test("non-http URL returns nil from normalizedStorageURL")
    func nonHTTPReturnsNil() throws {
        let url = try #require(URL(string: "feed://example.com/rss"))
        #expect(FeedURL.normalizedStorageURL(url) == nil)
    }

    @Test("default port 443 dropped from storage URL")
    func defaultPort443DroppedFromStorageURL() throws {
        let url = try #require(URL(string: "https://example.com:443/feed"))
        let stored = FeedURL.normalizedStorageURL(url)
        #expect(stored?.port == nil)
    }
}
