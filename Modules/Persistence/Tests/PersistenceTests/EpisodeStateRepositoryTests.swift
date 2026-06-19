import Foundation
import Testing
@testable import Persistence

@Suite("EpisodeStateRepository", .serialized)
struct EpisodeStateRepositoryTests {
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

    // MARK: - savePosition

    @Test("savePosition creates state row on first call")
    func savePositionCreatesRow() async throws {
        let db = try await makeDB()
        let podcastID = try await insertPodcast(in: db)
        let repo = EpisodeStateRepository(database: db)

        let before = try await repo.fetch(podcastID: podcastID, guid: "ep-1")
        #expect(before == nil)

        try await repo.savePosition(podcastID: podcastID, guid: "ep-1", position: 30, now: 1_700_001_000)

        let after = try await repo.fetch(podcastID: podcastID, guid: "ep-1")
        #expect(after?.playPosition == 30)
        #expect(after?.playState == .inProgress)
        #expect(after?.lastPlayedAt == 1_700_001_000)
    }

    @Test("savePosition updates position on subsequent calls")
    func savePositionUpdatesPosition() async throws {
        let db = try await makeDB()
        let podcastID = try await insertPodcast(in: db)
        let repo = EpisodeStateRepository(database: db)

        try await repo.savePosition(podcastID: podcastID, guid: "ep-1", position: 60, now: 1_700_001_000)
        try await repo.savePosition(podcastID: podcastID, guid: "ep-1", position: 120, now: 1_700_002_000)

        let state = try await repo.fetch(podcastID: podcastID, guid: "ep-1")
        #expect(state?.playPosition == 120)
        #expect(state?.lastPlayedAt == 1_700_002_000)
    }

    @Test("savePosition does not overwrite played state")
    func savePositionDoesNotOverwritePlayed() async throws {
        let db = try await makeDB()
        let podcastID = try await insertPodcast(in: db)
        let repo = EpisodeStateRepository(database: db)

        // Mark the episode as fully played.
        try await repo.markPlayed(podcastID: podcastID, guid: "ep-1", now: 1_700_001_000)

        // Simulate user scrubbing back; savePosition must not flip state back to inProgress.
        try await repo.savePosition(podcastID: podcastID, guid: "ep-1", position: 300, now: 1_700_002_000)

        let state = try await repo.fetch(podcastID: podcastID, guid: "ep-1")
        #expect(state?.playState == .played, "played state must not be overwritten by savePosition")
        #expect(state?.playPosition == 300, "position update is still applied")
    }

    // MARK: - markPlayed

    @Test("markPlayed creates a played row with zero position")
    func markPlayedCreatesRow() async throws {
        let db = try await makeDB()
        let podcastID = try await insertPodcast(in: db)
        let repo = EpisodeStateRepository(database: db)

        try await repo.markPlayed(podcastID: podcastID, guid: "ep-1", now: 1_700_001_000)

        let state = try await repo.fetch(podcastID: podcastID, guid: "ep-1")
        #expect(state?.playState == .played)
        #expect(state?.playPosition == 0)
        #expect(state?.completedAt == 1_700_001_000)
        #expect(state?.lastPlayedAt == 1_700_001_000)
    }

    @Test("markPlayed overwrites inProgress row")
    func markPlayedOverwritesInProgress() async throws {
        let db = try await makeDB()
        let podcastID = try await insertPodcast(in: db)
        let repo = EpisodeStateRepository(database: db)

        try await repo.savePosition(podcastID: podcastID, guid: "ep-1", position: 3500, now: 1_700_001_000)
        try await repo.markPlayed(podcastID: podcastID, guid: "ep-1", now: 1_700_002_000)

        let state = try await repo.fetch(podcastID: podcastID, guid: "ep-1")
        #expect(state?.playState == .played)
        #expect(state?.playPosition == 0)
        #expect(state?.completedAt == 1_700_002_000)
    }

    // MARK: - markUnplayed

    @Test("markUnplayed resets all progress fields")
    func markUnplayedResetsFields() async throws {
        let db = try await makeDB()
        let podcastID = try await insertPodcast(in: db)
        let repo = EpisodeStateRepository(database: db)

        try await repo.markPlayed(podcastID: podcastID, guid: "ep-1", now: 1_700_001_000)
        try await repo.markUnplayed(podcastID: podcastID, guid: "ep-1")

        let state = try await repo.fetch(podcastID: podcastID, guid: "ep-1")
        #expect(state?.playState == .unplayed)
        #expect(state?.playPosition == 0)
        #expect(state?.completedAt == nil)
    }

    @Test("markUnplayed creates unplayed row when no prior state")
    func markUnplayedCreatesRow() async throws {
        let db = try await makeDB()
        let podcastID = try await insertPodcast(in: db)
        let repo = EpisodeStateRepository(database: db)

        try await repo.markUnplayed(podcastID: podcastID, guid: "ep-1")

        let state = try await repo.fetch(podcastID: podcastID, guid: "ep-1")
        #expect(state?.playState == .unplayed)
        #expect(state?.playPosition == 0)
    }

    // MARK: - setDownloadState

    @Test("setDownloadState creates row and round-trips")
    func setDownloadStateRoundTrips() async throws {
        let db = try await makeDB()
        let podcastID = try await insertPodcast(in: db)
        let repo = EpisodeStateRepository(database: db)

        try await repo.setDownloadState(
            podcastID: podcastID,
            guid: "ep-1",
            state: .downloaded,
            path: "/Library/Podcasts/ep-1.mp3",
            bytes: 45_000_000
        )

        let state = try await repo.fetch(podcastID: podcastID, guid: "ep-1")
        #expect(state?.downloadState == .downloaded)
        #expect(state?.downloadPath == "/Library/Podcasts/ep-1.mp3")
        #expect(state?.downloadBytes == 45_000_000)
    }

    @Test("setDownloadState does not touch play fields")
    func setDownloadStatePreservesPlayFields() async throws {
        let db = try await makeDB()
        let podcastID = try await insertPodcast(in: db)
        let repo = EpisodeStateRepository(database: db)

        try await repo.savePosition(podcastID: podcastID, guid: "ep-1", position: 500, now: 1_700_001_000)
        try await repo.setDownloadState(
            podcastID: podcastID,
            guid: "ep-1",
            state: .downloaded,
            path: "/tmp/ep-1.mp3",
            bytes: 10000
        )

        let state = try await repo.fetch(podcastID: podcastID, guid: "ep-1")
        #expect(state?.playPosition == 500, "download upsert must not reset play position")
        #expect(state?.playState == .inProgress, "download upsert must not reset play state")
        #expect(state?.downloadState == .downloaded)
    }

    // MARK: - fetchAll

    @Test("fetchAll returns all state rows for a podcast")
    func fetchAllReturnsAll() async throws {
        let db = try await makeDB()
        let podcastID = try await insertPodcast(in: db)
        let repo = EpisodeStateRepository(database: db)

        try await repo.savePosition(podcastID: podcastID, guid: "ep-1", position: 100, now: 1_700_001_000)
        try await repo.savePosition(podcastID: podcastID, guid: "ep-2", position: 200, now: 1_700_001_000)

        let all = try await repo.fetchAll(podcastID: podcastID)
        #expect(all.count == 2)
        let guids = Set(all.map(\.guid))
        #expect(guids == ["ep-1", "ep-2"])
    }

    // MARK: - observe

    @Test("observe emits initial value then again on change")
    func observeEmitsOnChange() async throws {
        let db = try await makeDB()
        let podcastID = try await insertPodcast(in: db)
        let repo = EpisodeStateRepository(database: db)
        let stream = await repo.observe(podcastID: podcastID)
        var iterator = stream.makeAsyncIterator()

        let initial = try await iterator.next()
        #expect(initial?.isEmpty == true)

        try await repo.savePosition(podcastID: podcastID, guid: "ep-1", position: 60, now: 1_700_001_000)

        let updated = try await iterator.next()
        #expect(updated?.count == 1)
        #expect(updated?.first?.playPosition == 60)
    }

    // MARK: - Cascade

    @Test("state rows cascade-delete when the parent podcast is deleted")
    func stateCascadesOnPodcastDelete() async throws {
        let db = try await makeDB()
        let podcastID = try await insertPodcast(in: db)
        let podcastRepo = PodcastRepository(database: db)
        let stateRepo = EpisodeStateRepository(database: db)

        try await stateRepo.savePosition(podcastID: podcastID, guid: "ep-1", position: 100, now: 1_700_001_000)

        let beforeDelete = try await stateRepo.fetch(podcastID: podcastID, guid: "ep-1")
        #expect(beforeDelete != nil)

        try await podcastRepo.delete(id: podcastID)

        let afterDelete = try await stateRepo.fetch(podcastID: podcastID, guid: "ep-1")
        #expect(afterDelete == nil, "state must cascade-delete with the parent podcast")
    }
}
