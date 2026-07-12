import Foundation
import Testing
@testable import Persistence

@Suite("PodcastRepository", .serialized)
struct PodcastRepositoryTests {
    private func makeDB() async throws -> Database {
        try await Database(location: .inMemory)
    }

    private func sample(
        feedURL: String = "https://example.test/feed.rss",
        title: String = "Test Show",
        sortIndex: Int = 0
    ) -> Podcast {
        Podcast(
            feedURL: feedURL,
            title: title,
            author: "Test Author",
            sortIndex: sortIndex,
            addedAt: 1_700_000_000
        )
    }

    // MARK: - Basic CRUD

    @Test("insert then fetch returns the same row")
    func insertAndFetch() async throws {
        let db = try await makeDB()
        let repo = PodcastRepository(database: db)
        let id = try await repo.insert(self.sample())
        let fetched = try await repo.fetch(id: id)
        #expect(fetched.feedURL == "https://example.test/feed.rss")
        #expect(fetched.title == "Test Show")
        #expect(fetched.id == id)
    }

    @Test("podcastGUID round-trips through insert and fetch (M024 column)")
    func podcastGUIDRoundTrips() async throws {
        let db = try await makeDB()
        let repo = PodcastRepository(database: db)
        var show = self.sample()
        show.podcastGUID = "ead4c236-bf58-58c6-a2c6-a6b28d128cb6"
        let id = try await repo.insert(show)
        let fetched = try await repo.fetch(id: id)
        #expect(fetched.podcastGUID == "ead4c236-bf58-58c6-a2c6-a6b28d128cb6")
    }

    @Test("fundingText round-trips through insert and fetch (M025 column)")
    func fundingTextRoundTrips() async throws {
        let db = try await makeDB()
        let repo = PodcastRepository(database: db)
        var show = self.sample()
        show.fundingURL = "https://example.test/support"
        show.fundingText = "Support the show"
        let id = try await repo.insert(show)
        let fetched = try await repo.fetch(id: id)
        #expect(fetched.fundingURL == "https://example.test/support")
        #expect(fetched.fundingText == "Support the show")
    }

    @Test("podcast:person credits round-trip through the persons_json column (M028)")
    func personsRoundTrip() async throws {
        let db = try await makeDB()
        let repo = PodcastRepository(database: db)
        var show = self.sample()
        show.persons = [
            PodcastPerson(name: "Host A", role: "host", imageURL: "https://x.test/a.jpg", href: "https://x.test/a"),
            PodcastPerson(name: "Guest B", role: "guest"),
        ]
        let id = try await repo.insert(show)
        let fetched = try await repo.fetch(id: id)
        #expect(fetched.persons.count == 2)
        #expect(fetched.persons.first?.name == "Host A")
        #expect(fetched.persons.first?.imageURL == "https://x.test/a.jpg")
        #expect(fetched.persons.last?.role == "guest")
        // Empty list stays NULL rather than an empty-array blob.
        var bare = self.sample(feedURL: "https://noppl.test/feed")
        bare.persons = []
        let id2 = try await repo.insert(bare)
        #expect(try await repo.fetch(id: id2).personsJSON == nil)
    }

    @Test("fetch throws notFound for missing id")
    func fetchMissing() async throws {
        let db = try await makeDB()
        let repo = PodcastRepository(database: db)
        await #expect(throws: (any Error).self) {
            try await repo.fetch(id: 9999)
        }
    }

    @Test("fetchByFeedURL returns nil when no match")
    func fetchByFeedURLMiss() async throws {
        let db = try await makeDB()
        let repo = PodcastRepository(database: db)
        let result = try await repo.fetchByFeedURL("https://nope.test/feed")
        #expect(result == nil)
    }

    @Test("delete removes the row")
    func deleteRow() async throws {
        let db = try await makeDB()
        let repo = PodcastRepository(database: db)
        let id = try await repo.insert(self.sample())
        try await repo.delete(id: id)
        let result = try await repo.fetchByFeedURL("https://example.test/feed.rss")
        #expect(result == nil)
    }

    @Test("setSortIndex updates only sort_index")
    func setSortIndex() async throws {
        let db = try await makeDB()
        let repo = PodcastRepository(database: db)
        let id = try await repo.insert(self.sample(sortIndex: 0))
        try await repo.setSortIndex(id: id, sortIndex: 42)
        let fetched = try await repo.fetch(id: id)
        #expect(fetched.sortIndex == 42)
        #expect(fetched.title == "Test Show")
    }

    // MARK: - upsertByFeedURL

    @Test("upsertByFeedURL inserts when feed is new")
    func upsertInserts() async throws {
        let db = try await makeDB()
        let repo = PodcastRepository(database: db)
        let id = try await repo.upsertByFeedURL(self.sample())
        let fetched = try await repo.fetch(id: id)
        #expect(fetched.title == "Test Show")
    }

    @Test("upsertByFeedURL updates content and preserves identity fields")
    func upsertPreservesIdentityFields() async throws {
        let db = try await makeDB()
        let repo = PodcastRepository(database: db)

        // Insert original row with user-owned fields.
        var original = self.sample()
        original.subscribed = true
        original.autoDownload = true
        original.sortIndex = 5
        original.addedAt = 1_700_000_000
        let id = try await repo.upsertByFeedURL(original)

        // Simulate a feed refresh: same feedURL, updated content, different user-owned values.
        var refreshed = self.sample()
        refreshed.title = "Updated Show Title"
        refreshed.author = "New Author"
        refreshed.subscribed = false // incoming value; must be ignored
        refreshed.autoDownload = false // incoming value; must be ignored
        refreshed.sortIndex = 99 // incoming value; must be ignored
        refreshed.addedAt = 1_999_999_999 // incoming value; must be ignored

        let id2 = try await repo.upsertByFeedURL(refreshed)
        #expect(id2 == id, "upsert must return the same rowid")

        let fetched = try await repo.fetch(id: id)
        // Content updated:
        #expect(fetched.title == "Updated Show Title")
        #expect(fetched.author == "New Author")
        // Identity fields preserved:
        #expect(fetched.subscribed == true)
        #expect(fetched.autoDownload == true)
        #expect(fetched.sortIndex == 5)
        #expect(fetched.addedAt == 1_700_000_000)
    }

    @Test("upsertByFeedURL preserves the cached artwork_path but refreshes artwork_url")
    func upsertPreservesArtworkPath() async throws {
        let db = try await makeDB()
        let repo = PodcastRepository(database: db)

        var original = self.sample()
        original.artworkURL = "https://cdn.test/art-v1.jpg"
        original.artworkPath = "/Library/Application Support/Bocan/Podcasts/Artwork/1/abc.jpg"
        let id = try await repo.upsertByFeedURL(original)

        // A refresh parse carries the (possibly new) URL but never a local path.
        var refreshed = self.sample()
        refreshed.artworkURL = "https://cdn.test/art-v2.jpg"
        refreshed.artworkPath = nil
        try await repo.upsertByFeedURL(refreshed)

        let fetched = try await repo.fetch(id: id)
        #expect(fetched.artworkPath == original.artworkPath, "local cache path must survive a refresh")
        #expect(fetched.artworkURL == "https://cdn.test/art-v2.jpg", "feed-derived URL must refresh")
    }

    @Test("upsertByFeedURL preserves the cached artwork_hash (M033 column)")
    func upsertPreservesArtworkHash() async throws {
        let db = try await makeDB()
        let repo = PodcastRepository(database: db)

        var original = self.sample()
        original.artworkPath = "/tmp/art/abc.jpg"
        original.artworkHash = "cafe1234"
        let id = try await repo.upsertByFeedURL(original)

        // A refresh parse never carries the locally derived hash.
        var refreshed = self.sample()
        refreshed.artworkHash = nil
        try await repo.upsertByFeedURL(refreshed)

        let fetched = try await repo.fetch(id: id)
        #expect(fetched.artworkHash == "cafe1234", "locally derived hash must survive a refresh")
    }

    // MARK: - Artwork path + hash

    @Test("setArtwork writes path and hash together; fetchByArtworkHash resolves the show")
    func setArtworkAndFetchByHash() async throws {
        let db = try await makeDB()
        let repo = PodcastRepository(database: db)
        let id = try await repo.insert(self.sample())

        try await repo.setArtwork(id: id, path: "/tmp/art/abc.jpg", hash: "deadbeef")
        let fetched = try await repo.fetch(id: id)
        #expect(fetched.artworkPath == "/tmp/art/abc.jpg")
        #expect(fetched.artworkHash == "deadbeef")

        let byHash = try await repo.fetchByArtworkHash("deadbeef")
        #expect(byHash?.id == id)
        #expect(try await repo.fetchByArtworkHash("0000") == nil)
    }

    // MARK: - fetchAllSubscribed

    @Test("fetchAllSubscribed orders by sort_index then title")
    func fetchAllSubscribedOrdering() async throws {
        let db = try await makeDB()
        let repo = PodcastRepository(database: db)
        try await repo.insert(self.sample(feedURL: "https://b.test/feed", title: "B Show", sortIndex: 2))
        try await repo.insert(self.sample(feedURL: "https://a.test/feed", title: "A Show", sortIndex: 1))
        try await repo.insert(self.sample(feedURL: "https://c.test/feed", title: "C Show", sortIndex: 2))
        let all = try await repo.fetchAllSubscribed()
        #expect(all.map(\.title) == ["A Show", "B Show", "C Show"])
    }

    @Test("fetchAllSubscribed excludes unsubscribed rows")
    func fetchAllSubscribedFilters() async throws {
        let db = try await makeDB()
        let repo = PodcastRepository(database: db)
        var subscribed = self.sample(feedURL: "https://sub.test/feed", title: "Subscribed")
        subscribed.subscribed = true
        var unsubscribed = self.sample(feedURL: "https://unsub.test/feed", title: "Unsubscribed")
        unsubscribed.subscribed = false
        try await repo.insert(subscribed)
        try await repo.insert(unsubscribed)
        let all = try await repo.fetchAllSubscribed()
        #expect(all.count == 1)
        #expect(all.first?.title == "Subscribed")
    }

    // MARK: - fetchStale

    @Test("fetchStale includes rows with NULL last_refreshed_at")
    func fetchStaleIncludesNullRefresh() async throws {
        let db = try await makeDB()
        let repo = PodcastRepository(database: db)
        var podcast = self.sample()
        podcast.lastRefreshedAt = nil
        try await repo.insert(podcast)
        let stale = try await repo.fetchStale(olderThan: 3600, now: 1_700_100_000)
        #expect(stale.count == 1)
    }

    @Test("fetchStale includes rows older than the interval")
    func fetchStaleIncludesOld() async throws {
        let db = try await makeDB()
        let repo = PodcastRepository(database: db)
        var podcast = self.sample()
        podcast.lastRefreshedAt = 1_700_000_000 // old
        try await repo.insert(podcast)
        let stale = try await repo.fetchStale(olderThan: 3600, now: 1_700_100_000)
        #expect(stale.count == 1)
    }

    @Test("fetchStale excludes recently refreshed rows")
    func fetchStaleExcludesFresh() async throws {
        let db = try await makeDB()
        let repo = PodcastRepository(database: db)
        var podcast = self.sample()
        podcast.lastRefreshedAt = 1_700_099_000 // 1000s ago; interval is 3600s
        try await repo.insert(podcast)
        let stale = try await repo.fetchStale(olderThan: 3600, now: 1_700_100_000)
        #expect(stale.isEmpty)
    }

    // MARK: - Observation

    @Test("observeSubscribed emits initial value then again on insert")
    func observeSubscribedEmitsOnInsert() async throws {
        let db = try await makeDB()
        let repo = PodcastRepository(database: db)
        let stream = await repo.observeSubscribed()
        var iterator = stream.makeAsyncIterator()

        let initial = try await iterator.next()
        #expect(initial?.isEmpty == true)

        try await repo.insert(self.sample())
        let updated = try await iterator.next()
        #expect(updated?.count == 1)
    }

    // MARK: - Per-show settings (M027)

    @Test("per-show settings round-trip through insert and fetch")
    func perShowSettingsRoundTrip() async throws {
        let db = try await makeDB()
        let repo = PodcastRepository(database: db)
        var podcast = self.sample()
        podcast.playbackSpeed = 1.5
        podcast.episodeSort = "oldest"
        podcast.retentionLimit = 25
        podcast.showType = "serial"
        let id = try await repo.insert(podcast)

        let fetched = try await repo.fetch(id: id)
        #expect(fetched.playbackSpeed == 1.5)
        #expect(fetched.episodeSort == "oldest")
        #expect(fetched.retentionLimit == 25)
        #expect(fetched.showType == "serial")
    }

    @Test("per-show settings default to nil")
    func perShowSettingsDefaultNil() async throws {
        let db = try await makeDB()
        let repo = PodcastRepository(database: db)
        let id = try await repo.insert(self.sample())
        let fetched = try await repo.fetch(id: id)
        #expect(fetched.playbackSpeed == nil)
        #expect(fetched.episodeSort == nil)
        #expect(fetched.retentionLimit == nil)
        #expect(fetched.showType == nil)
    }

    @Test("each per-show setter updates only its own column")
    func settersUpdateSingleColumn() async throws {
        let db = try await makeDB()
        let repo = PodcastRepository(database: db)
        let id = try await repo.insert(self.sample())

        try await repo.setPlaybackSpeed(2.0, id: id)
        try await repo.setEpisodeSort("newest", id: id)
        try await repo.setRetentionLimit(50, id: id)
        var fetched = try await repo.fetch(id: id)
        #expect(fetched.playbackSpeed == 2.0)
        #expect(fetched.episodeSort == "newest")
        #expect(fetched.retentionLimit == 50)

        try await repo.setPlaybackSpeed(nil, id: id)
        fetched = try await repo.fetch(id: id)
        #expect(fetched.playbackSpeed == nil)
        #expect(fetched.episodeSort == "newest", "other columns untouched")
        #expect(fetched.retentionLimit == 50)
    }

    @Test("upsertByFeedURL preserves overrides and refreshes show_type")
    func upsertPreservesOverridesRefreshesShowType() async throws {
        let db = try await makeDB()
        let repo = PodcastRepository(database: db)
        var first = self.sample()
        first.showType = "episodic"
        let id = try await repo.insert(first)
        try await repo.setPlaybackSpeed(1.25, id: id)
        try await repo.setEpisodeSort("oldest", id: id)
        try await repo.setRetentionLimit(10, id: id)

        var refreshed = self.sample(title: "Renamed Show")
        refreshed.showType = "serial"
        try await repo.upsertByFeedURL(refreshed)

        let fetched = try await repo.fetchByFeedURL(first.feedURL)
        #expect(fetched?.title == "Renamed Show")
        #expect(fetched?.showType == "serial", "feed-derived show_type refreshes")
        #expect(fetched?.playbackSpeed == 1.25, "override preserved")
        #expect(fetched?.episodeSort == "oldest", "override preserved")
        #expect(fetched?.retentionLimit == 10, "override preserved")
    }

    @Test("resolvedEpisodeSort: explicit override wins, else derived from show type")
    func resolvedEpisodeSortDerivation() {
        var podcast = self.sample()
        #expect(podcast.resolvedEpisodeSort == .newest, "no override, no type -> newest")

        podcast.showType = "serial"
        #expect(podcast.resolvedEpisodeSort == .oldest, "serial -> oldest")

        podcast.showType = "episodic"
        #expect(podcast.resolvedEpisodeSort == .newest, "episodic -> newest")

        podcast.episodeSort = "oldest"
        #expect(podcast.resolvedEpisodeSort == .oldest, "explicit override wins over episodic")

        podcast.episodeSort = "garbage"
        #expect(podcast.resolvedEpisodeSort == .newest, "invalid override falls back to derived")
    }

    // MARK: - Retention

    @Test("pruneEpisodes keeps newest N plus exemptions and leaves state rows intact")
    func pruneKeepsNewestAndExemptions() async throws {
        let db = try await makeDB()
        let repo = PodcastRepository(database: db)
        let episodeRepo = EpisodeRepository(database: db)
        let stateRepo = EpisodeStateRepository(database: db)
        let id = try await repo.insert(self.sample())

        try await episodeRepo.upsertAll((1 ... 5).map { index in
            PodcastEpisode(
                podcastID: id,
                guid: "ep-\(index)",
                title: "E\(index)",
                audioURL: "https://x/\(index).mp3",
                publishedAt: Double(index * 100),
                addedAt: 0
            )
        })
        // Exempt the two oldest: ep-1 played, ep-2 downloaded.
        try await stateRepo.markPlayed(podcastID: id, guid: "ep-1", now: 1)
        try await stateRepo.setDownloadState(podcastID: id, guid: "ep-2", state: .downloaded, path: "/tmp/x", bytes: 1)

        // Keep newest 1 (ep-5); ep-3/ep-4 are cold and deleted; ep-1/ep-2 exempt.
        try await repo.pruneEpisodes(podcastID: id, keepNewest: 1)

        let remaining = try await Set(episodeRepo.fetchForPodcast(podcastID: id).map(\.guid))
        #expect(remaining == ["ep-1", "ep-2", "ep-5"])

        let state1 = try await stateRepo.fetch(podcastID: id, guid: "ep-1")
        let state2 = try await stateRepo.fetch(podcastID: id, guid: "ep-2")
        #expect(state1 != nil, "state rows are never deleted by prune")
        #expect(state2 != nil)
    }

    @Test("pruneEpisodes with a nil limit is a no-op")
    func pruneNilNoOp() async throws {
        let db = try await makeDB()
        let repo = PodcastRepository(database: db)
        let episodeRepo = EpisodeRepository(database: db)
        let id = try await repo.insert(self.sample())
        try await episodeRepo.upsertAll((1 ... 3).map { index in
            PodcastEpisode(
                podcastID: id,
                guid: "ep-\(index)",
                title: "E\(index)",
                audioURL: "https://x/\(index).mp3",
                publishedAt: Double(index),
                addedAt: 0
            )
        })
        try await repo.pruneEpisodes(podcastID: id, keepNewest: nil)
        let count = try await episodeRepo.fetchForPodcast(podcastID: id).count
        #expect(count == 3)
    }
}
