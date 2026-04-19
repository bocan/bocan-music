import AudioEngine
import Foundation
import Persistence
import Testing
@testable import Playback

// MARK: - QueuePlayerTests

@Suite("QueuePlayer")
struct QueuePlayerTests {
    // These tests verify the queue-player state machine without performing
    // actual audio decoding. They use a lightweight in-memory database.

    @Test("QueuePlayer can be initialised without crashing")
    func initDoesNotCrash() async throws {
        let engine = AudioEngine()
        let db = try await Database(location: .inMemory)
        _ = QueuePlayer(engine: engine, database: db)
    }

    @Test("playNext enqueues items after current")
    func playNextEnqueues() async throws {
        let engine = AudioEngine()
        let db = try await Database(location: .inMemory)
        let player = QueuePlayer(engine: engine, database: db)

        let repo = TrackRepository(database: db)
        let ids = try await insertTestTracks(repo: repo, count: 3)

        // Populate queue without playing audio files.
        try await player.addToQueue([ids[0], ids[1]])
        let initial = await player.queue.items
        await player.queue.replace(with: initial, startAt: 0) // set current to index 0

        // playNext inserts ids[2] immediately after current (index 0).
        try await player.playNext([ids[2]])

        let queueItems = await player.queue.items
        #expect(queueItems.count == 3)
        #expect(queueItems[1].trackID == ids[2])
    }

    @Test("addToQueue appends to end")
    func addToQueueAppends() async throws {
        let engine = AudioEngine()
        let db = try await Database(location: .inMemory)
        let player = QueuePlayer(engine: engine, database: db)

        let repo = TrackRepository(database: db)
        let ids = try await insertTestTracks(repo: repo, count: 2)
        let extraID = try await repo.insert(self.makeTrack(n: 99))

        try await player.addToQueue(ids)
        try await player.addToQueue([extraID])

        let queueItems = await player.queue.items
        #expect(queueItems.last?.trackID == extraID)
    }

    @Test("setRepeat changes queue repeat mode")
    func setRepeatChangesMode() async throws {
        let engine = AudioEngine()
        let db = try await Database(location: .inMemory)
        let player = QueuePlayer(engine: engine, database: db)
        await player.setRepeat(.all)
        let mode = await player.queue.repeatMode
        #expect(mode == .all)
    }

    @Test("setShuffle toggles shuffle state")
    func setShuffleToggles() async throws {
        let engine = AudioEngine()
        let db = try await Database(location: .inMemory)
        let player = QueuePlayer(engine: engine, database: db)
        let repo = TrackRepository(database: db)
        let ids = try await insertTestTracks(repo: repo, count: 5)

        // Populate queue without starting playback.
        try await player.addToQueue(ids)

        await player.setShuffle(true)
        let state = await player.queue.shuffleState
        if case .on = state {} else {
            Issue.record("Expected .on, got \(state)")
        }

        await player.setShuffle(false)
        let state2 = await player.queue.shuffleState
        #expect(state2 == .off)
    }

    // MARK: - Helpers

    private func makeTrack(n: Int) -> Track {
        let now = Int64(Date().timeIntervalSince1970)
        return Track(
            fileURL: "/tmp/track\(n).flac",
            fileFormat: "flac",
            duration: 200,
            title: "Track \(n)",
            addedAt: now,
            updatedAt: now
        )
    }

    private func insertTestTracks(repo: TrackRepository, count: Int) async throws -> [Int64] {
        var ids: [Int64] = []
        for i in 1 ... count {
            let id = try await repo.insert(self.makeTrack(n: i))
            ids.append(id)
        }
        return ids
    }
}
