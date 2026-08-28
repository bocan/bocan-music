import Foundation
import Testing
@testable import Persistence

/// Every `podcasts` column and what a feed refresh (`upsertByFeedURL` with
/// a parse-shaped row) does to it. Adding a column to the table without
/// adding it here fails, so its refresh behaviour is decided deliberately
/// rather than by omission (#421; the #409 failure mode).
@Suite("Podcast refresh behaviour per column (#421)")
struct PodcastRefreshBehaviourTests {
    private enum Behaviour { case key, preserved, refreshed, preservedUnlessProvided }

    private static let refreshBehaviour: [String: Behaviour] = [
        "id": .preserved, "feed_url": .key, "added_at": .preserved,
        "title": .refreshed, "author": .refreshed, "description": .refreshed, "artwork_url": .refreshed,
        "link": .refreshed, "language": .refreshed, "explicit": .refreshed, "categories_json": .refreshed,
        "owner_name": .refreshed, "owner_email": .refreshed, "copyright": .refreshed,
        "funding_url": .refreshed, "funding_text": .refreshed, "podcast_guid": .refreshed,
        "http_etag": .refreshed, "http_last_modified": .refreshed, "last_refreshed_at": .refreshed,
        "last_refresh_error": .refreshed, "show_type": .refreshed, "persons_json": .refreshed, "podroll_json": .refreshed,
        "artwork_path": .preserved, "artwork_hash": .preserved,
        "auto_download": .preserved, "playback_speed": .preserved, "episode_sort": .preserved, "retention_limit": .preserved,
        "itunes_collection_id": .preservedUnlessProvided, "podcast_index_id": .preservedUnlessProvided,
    ]

    private static let feedURL = "https://example.test/feed.rss"

    private static func fullyPopulated() -> Podcast {
        var podcast = Podcast(feedURL: self.feedURL, title: "T1", addedAt: 1_700_000_000)
        podcast.author = "A1"
        podcast.description = "D1"
        podcast.artworkURL = "u1"
        podcast.artworkPath = "/art/1"
        podcast.artworkHash = "h1"
        podcast.link = "l1"
        podcast.language = "en"
        podcast.explicit = true
        podcast.categoriesJSON = Data("[\"a\"]".utf8)
        podcast.ownerName = "O1"
        podcast.ownerEmail = "e1"
        podcast.copyright = "c1"
        podcast.fundingURL = "f1"
        podcast.fundingText = "t1"
        podcast.itunesCollectionID = 11
        podcast.podcastIndexID = 12
        podcast.podcastGUID = "g1"
        podcast.httpETag = "et1"
        podcast.httpLastModified = "lm1"
        podcast.lastRefreshedAt = 1
        podcast.lastRefreshError = "err1"
        podcast.autoDownload = true
        podcast.playbackSpeed = 1.5
        podcast.episodeSort = "oldest"
        podcast.retentionLimit = 5
        podcast.showType = "serial"
        podcast.personsJSON = Data("[1]".utf8)
        podcast.podrollJSON = Data("[2]".utf8)
        return podcast
    }

    /// What a refresh parse produces: feed fields new, user and local fields absent.
    private static func parseShaped() -> Podcast {
        var podcast = Podcast(feedURL: self.feedURL, title: "T2", addedAt: 999)
        podcast.author = "A2"
        podcast.description = "D2"
        podcast.artworkURL = "u2"
        podcast.link = "l2"
        podcast.language = "fr"
        podcast.explicit = false
        podcast.podcastGUID = "g2"
        podcast.httpETag = "et2"
        podcast.httpLastModified = "lm2"
        podcast.lastRefreshedAt = 2
        podcast.showType = "episodic"
        return podcast
    }

    @Test("every column has a decided behaviour and the table matches the schema")
    func tableMatchesSchema() async throws {
        let db = try await Database(location: .inMemory)
        let columns = try await db.read { grdb in try grdb.columns(in: "podcasts").map(\.name) }
        let undecided = Set(columns).symmetricDifference(Self.refreshBehaviour.keys)
        #expect(undecided.isEmpty, "decide the refresh behaviour of: \(undecided)")
    }

    @Test("upsertByFeedURL preserves user and local columns and refreshes feed columns")
    func upsertHonoursTable() async throws {
        let db = try await Database(location: .inMemory)
        let repo = PodcastRepository(database: db)
        let id = try await repo.upsertByFeedURL(Self.fullyPopulated())
        #expect(try await repo.upsertByFeedURL(Self.parseShaped()) == id)
        let row = try await repo.fetch(id: id)
        Self.assertPreserved(row)
        Self.assertRefreshed(row)
    }

    private static func assertPreserved(_ row: Podcast) {
        #expect(row.addedAt == 1_700_000_000)
        #expect(row.artworkPath == "/art/1")
        #expect(row.artworkHash == "h1")
        #expect(row.autoDownload == true)
        #expect(row.playbackSpeed == 1.5)
        #expect(row.episodeSort == "oldest")
        #expect(row.retentionLimit == 5)
        #expect(row.itunesCollectionID == 11)
        #expect(row.podcastIndexID == 12)
    }

    private static func assertRefreshed(_ row: Podcast) {
        #expect(row.title == "T2")
        #expect(row.author == "A2")
        #expect(row.description == "D2")
        #expect(row.artworkURL == "u2")
        #expect(row.link == "l2")
        #expect(row.language == "fr")
        #expect(row.explicit == false)
        #expect(row.categoriesJSON == nil)
        #expect(row.ownerName == nil)
        #expect(row.ownerEmail == nil)
        #expect(row.copyright == nil)
        #expect(row.fundingURL == nil)
        #expect(row.fundingText == nil)
        #expect(row.podcastGUID == "g2")
        #expect(row.httpETag == "et2")
        #expect(row.httpLastModified == "lm2")
        #expect(row.lastRefreshedAt == 2)
        #expect(row.lastRefreshError == nil)
        #expect(row.showType == "episodic")
        #expect(row.personsJSON == nil)
        #expect(row.podrollJSON == nil)
    }
}
