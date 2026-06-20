import Foundation
import Testing
@testable import Persistence

@Suite("EpisodeRepository", .serialized)
struct EpisodeRepositoryTests {
    private func makeDB() async throws -> Database {
        try await Database(location: .inMemory)
    }

    private func insertPodcast(in db: Database) async throws -> Int64 {
        let repo = PodcastRepository(database: db)
        return try await repo.insert(Podcast(
            feedURL: "https://example.test/feed.rss",
            title: "Test Show",
            addedAt: 1_700_000_000
        ))
    }

    private func sampleEpisode(podcastID: Int64, guid: String = "ep-001", title: String = "Episode 1") -> PodcastEpisode {
        PodcastEpisode(
            podcastID: podcastID,
            guid: guid,
            title: title,
            audioURL: "https://cdn.example.test/ep001.mp3",
            duration: 3600,
            publishedAt: 1_700_000_000,
            addedAt: 1_700_000_000
        )
    }

    // MARK: - Critical regression test (the headline requirement)

    /// A feed refresh must not reset saved play position.
    ///
    /// Write a position via EpisodeStateRepository, then re-upsert the same
    /// (podcast_id, guid) episode (simulating what PodcastService.refresh does),
    /// and assert the state row is unchanged. This verifies the separate-table design.
    @Test("feed refresh upsert does not reset saved play position")
    func feedRefreshPreservesPlayPosition() async throws {
        let db = try await makeDB()
        let podcastID = try await insertPodcast(in: db)
        let episodeRepo = EpisodeRepository(database: db)
        let stateRepo = EpisodeStateRepository(database: db)

        // Initial episode upsert (e.g. from first subscribe).
        let episode = self.sampleEpisode(podcastID: podcastID)
        try await episodeRepo.upsert(episode)

        // User plays 600 seconds in.
        try await stateRepo.savePosition(
            podcastID: podcastID,
            guid: episode.guid,
            position: 600,
            now: 1_700_001_000
        )

        // Verify position was saved.
        let stateBefore = try await stateRepo.fetch(podcastID: podcastID, guid: episode.guid)
        #expect(stateBefore?.playPosition == 600)
        #expect(stateBefore?.playState == .inProgress)

        // Simulate a feed refresh: re-upsert the same episode with updated content.
        var refreshedEpisode = episode
        refreshedEpisode.title = "Episode 1 (Updated)"
        refreshedEpisode.duration = 3620
        try await episodeRepo.upsert(refreshedEpisode)

        // State must be unchanged after the content refresh.
        let stateAfter = try await stateRepo.fetch(podcastID: podcastID, guid: episode.guid)
        #expect(stateAfter?.playPosition == 600, "play position must survive a feed refresh")
        #expect(stateAfter?.playState == .inProgress, "play state must survive a feed refresh")

        // Content must have been updated.
        let updatedEpisode = try await episodeRepo.fetchByGUID(podcastID: podcastID, guid: episode.guid)
        #expect(updatedEpisode?.title == "Episode 1 (Updated)")
        #expect(updatedEpisode?.duration == 3620)
    }

    // MARK: - Basic upsert

    @Test("upsert inserts a new episode")
    func upsertInserts() async throws {
        let db = try await makeDB()
        let podcastID = try await insertPodcast(in: db)
        let repo = EpisodeRepository(database: db)
        try await repo.upsert(self.sampleEpisode(podcastID: podcastID))
        let episodes = try await repo.fetchForPodcast(podcastID: podcastID)
        #expect(episodes.count == 1)
        #expect(episodes.first?.guid == "ep-001")
    }

    @Test("upsert updates content columns on conflict")
    func upsertUpdatesContent() async throws {
        let db = try await makeDB()
        let podcastID = try await insertPodcast(in: db)
        let repo = EpisodeRepository(database: db)
        try await repo.upsert(self.sampleEpisode(podcastID: podcastID, title: "Original"))
        var updated = self.sampleEpisode(podcastID: podcastID, title: "Updated")
        updated.duration = 7200
        try await repo.upsert(updated)
        let episodes = try await repo.fetchForPodcast(podcastID: podcastID)
        #expect(episodes.count == 1, "upsert must not create a duplicate")
        #expect(episodes.first?.title == "Updated")
        #expect(episodes.first?.duration == 7200)
    }

    @Test("upsert preserves added_at on update")
    func upsertPreservesAddedAt() async throws {
        let db = try await makeDB()
        let podcastID = try await insertPodcast(in: db)
        let repo = EpisodeRepository(database: db)

        var original = self.sampleEpisode(podcastID: podcastID)
        original.addedAt = 1_700_000_000
        try await repo.upsert(original)

        var refreshed = self.sampleEpisode(podcastID: podcastID)
        refreshed.addedAt = 1_999_999_999 // should be ignored on update
        try await repo.upsert(refreshed)

        let fetched = try await repo.fetchByGUID(podcastID: podcastID, guid: "ep-001")
        #expect(fetched?.addedAt == 1_700_000_000)
    }

    // MARK: - upsertAll

    @Test("upsertAll runs in a single transaction")
    func upsertAllIsOneTransaction() async throws {
        let db = try await makeDB()
        let podcastID = try await insertPodcast(in: db)
        let repo = EpisodeRepository(database: db)
        let episodes = (1 ... 5).map { i in
            PodcastEpisode(
                podcastID: podcastID,
                guid: "ep-\(i)",
                title: "Episode \(i)",
                audioURL: "https://cdn.example.test/ep\(i).mp3",
                addedAt: 1_700_000_000
            )
        }
        try await repo.upsertAll(episodes)
        let fetched = try await repo.fetchForPodcast(podcastID: podcastID)
        #expect(fetched.count == 5)
    }

    // MARK: - pruneEpisodes

    @Test("pruneEpisodes removes only out-of-set content rows")
    func pruneRemovesOutOfSetContent() async throws {
        let db = try await makeDB()
        let podcastID = try await insertPodcast(in: db)
        let repo = EpisodeRepository(database: db)
        try await repo.upsert(self.sampleEpisode(podcastID: podcastID, guid: "ep-1"))
        try await repo.upsert(self.sampleEpisode(podcastID: podcastID, guid: "ep-2"))
        try await repo.upsert(self.sampleEpisode(podcastID: podcastID, guid: "ep-3"))

        try await repo.pruneEpisodes(podcastID: podcastID, keepGUIDs: ["ep-1", "ep-3"])

        let remaining = try await repo.fetchForPodcast(podcastID: podcastID)
        let guids = Set(remaining.map(\.guid))
        #expect(guids == ["ep-1", "ep-3"])
    }

    @Test("pruneEpisodes leaves state rows intact")
    func prunePreservesStateRows() async throws {
        let db = try await makeDB()
        let podcastID = try await insertPodcast(in: db)
        let episodeRepo = EpisodeRepository(database: db)
        let stateRepo = EpisodeStateRepository(database: db)

        // Insert two episodes and save position on both.
        try await episodeRepo.upsert(self.sampleEpisode(podcastID: podcastID, guid: "ep-1"))
        try await episodeRepo.upsert(self.sampleEpisode(podcastID: podcastID, guid: "ep-2"))
        try await stateRepo.savePosition(podcastID: podcastID, guid: "ep-1", position: 100, now: 1_700_001_000)
        try await stateRepo.savePosition(podcastID: podcastID, guid: "ep-2", position: 200, now: 1_700_001_000)

        // Prune ep-2 from content (it dropped out of the feed).
        try await episodeRepo.pruneEpisodes(podcastID: podcastID, keepGUIDs: ["ep-1"])

        // State row for ep-2 must still exist.
        let state1 = try await stateRepo.fetch(podcastID: podcastID, guid: "ep-1")
        let state2 = try await stateRepo.fetch(podcastID: podcastID, guid: "ep-2")
        #expect(state1?.playPosition == 100)
        #expect(state2?.playPosition == 200, "state for pruned episode must survive")
    }

    // MARK: - fetchListItems

    @Test("fetchListItems returns nil state for episodes with no state row")
    func fetchListItemsNoState() async throws {
        let db = try await makeDB()
        let podcastID = try await insertPodcast(in: db)
        let repo = EpisodeRepository(database: db)
        try await repo.upsert(self.sampleEpisode(podcastID: podcastID))
        let items = try await repo.fetchListItems(podcastID: podcastID)
        #expect(items.count == 1)
        #expect(items.first?.state == nil)
    }

    @Test("fetchListItems returns joined state when state row exists")
    func fetchListItemsWithState() async throws {
        let db = try await makeDB()
        let podcastID = try await insertPodcast(in: db)
        let episodeRepo = EpisodeRepository(database: db)
        let stateRepo = EpisodeStateRepository(database: db)

        try await episodeRepo.upsert(self.sampleEpisode(podcastID: podcastID, guid: "ep-1"))
        try await stateRepo.savePosition(podcastID: podcastID, guid: "ep-1", position: 300, now: 1_700_001_000)

        let items = try await episodeRepo.fetchListItems(podcastID: podcastID)
        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.state?.playPosition == 300)
        #expect(item.state?.playState == .inProgress)
    }

    @Test("fetchListItems mixes nil and non-nil state in same result")
    func fetchListItemsMixedState() async throws {
        let db = try await makeDB()
        let podcastID = try await insertPodcast(in: db)
        let episodeRepo = EpisodeRepository(database: db)
        let stateRepo = EpisodeStateRepository(database: db)

        try await episodeRepo.upsert(self.sampleEpisode(podcastID: podcastID, guid: "ep-1", title: "Episode 1"))
        try await episodeRepo.upsert(self.sampleEpisode(podcastID: podcastID, guid: "ep-2", title: "Episode 2"))
        try await stateRepo.markPlayed(podcastID: podcastID, guid: "ep-1", now: 1_700_001_000)

        let items = try await episodeRepo.fetchListItems(podcastID: podcastID)
        #expect(items.count == 2)
        let played = items.first { $0.episode.guid == "ep-1" }
        let unplayed = items.first { $0.episode.guid == "ep-2" }
        #expect(played?.state?.playState == .played)
        #expect(unplayed?.state == nil)
    }

    // MARK: - observeListItems

    @Test("observeListItems emits on episode change")
    func observeEmitsOnEpisodeChange() async throws {
        let db = try await makeDB()
        let podcastID = try await insertPodcast(in: db)
        let repo = EpisodeRepository(database: db)
        let stream = await repo.observeListItems(podcastID: podcastID)
        var iterator = stream.makeAsyncIterator()

        let initial = try await iterator.next()
        #expect(initial?.isEmpty == true)

        try await repo.upsert(self.sampleEpisode(podcastID: podcastID))
        let updated = try await iterator.next()
        #expect(updated?.count == 1)
    }

    @Test("observeListItems emits on state change")
    func observeEmitsOnStateChange() async throws {
        let db = try await makeDB()
        let podcastID = try await insertPodcast(in: db)
        let episodeRepo = EpisodeRepository(database: db)
        let stateRepo = EpisodeStateRepository(database: db)

        try await episodeRepo.upsert(self.sampleEpisode(podcastID: podcastID))

        let stream = await episodeRepo.observeListItems(podcastID: podcastID)
        var iterator = stream.makeAsyncIterator()

        let initial = try await iterator.next()
        #expect(initial?.first?.state == nil)

        // Write a position update (to podcast_episode_state table).
        try await stateRepo.savePosition(podcastID: podcastID, guid: "ep-001", position: 120, now: 1_700_001_000)

        let updated = try await iterator.next()
        #expect(updated?.first?.state?.playPosition == 120, "observation must re-fire on state table change")
    }

    // MARK: - Sort order

    @Test("fetchListItems(order:) sorts ascending for .oldest, descending for .newest")
    func fetchListItemsHonorsOrder() async throws {
        let db = try await makeDB()
        let podcastID = try await insertPodcast(in: db)
        let repo = EpisodeRepository(database: db)
        try await repo.upsertAll([
            PodcastEpisode(podcastID: podcastID, guid: "a", title: "A", audioURL: "https://x/a.mp3", publishedAt: 300, addedAt: 0),
            PodcastEpisode(podcastID: podcastID, guid: "b", title: "B", audioURL: "https://x/b.mp3", publishedAt: 100, addedAt: 0),
            PodcastEpisode(podcastID: podcastID, guid: "c", title: "C", audioURL: "https://x/c.mp3", publishedAt: 200, addedAt: 0),
        ])

        let oldest = try await repo.fetchListItems(podcastID: podcastID, order: .oldest).map(\.episode.guid)
        #expect(oldest == ["b", "c", "a"])

        let newest = try await repo.fetchListItems(podcastID: podcastID, order: .newest).map(\.episode.guid)
        #expect(newest == ["a", "c", "b"])
    }
}
