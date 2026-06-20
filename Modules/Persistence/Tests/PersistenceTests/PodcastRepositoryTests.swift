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
}
