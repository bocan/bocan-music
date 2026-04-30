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

    @Test("setStopAfterCurrent sets flag on queue")
    func setStopAfterCurrentSetsFlag() async throws {
        let engine = AudioEngine()
        let db = try await Database(location: .inMemory)
        let player = QueuePlayer(engine: engine, database: db)

        await player.setStopAfterCurrent(true)
        let flag = await player.queue.stopAfterCurrent
        #expect(flag == true)

        await player.setStopAfterCurrent(false)
        let flag2 = await player.queue.stopAfterCurrent
        #expect(flag2 == false)
    }

    @Test("setStopAfterCurrent emits stopAfterCurrentChanged change")
    func setStopAfterCurrentEmitsChange() async throws {
        let engine = AudioEngine()
        let db = try await Database(location: .inMemory)
        let player = QueuePlayer(engine: engine, database: db)

        // Collect the first stopAfterCurrentChanged event using a checked continuation.
        let flag = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let queue = player.queue
            Task {
                for await change in await queue.changes {
                    if case let .stopAfterCurrentChanged(enabled) = change {
                        cont.resume(returning: enabled)
                        break
                    }
                }
            }
            Task { await player.setStopAfterCurrent(true) }
        }
        #expect(flag == true)
    }

    @Test("handleTrackEnded honours stop-after-current over repeat-one (Phase 5 audit M4)")
    func stopAfterCurrentBeatsRepeatOne() async throws {
        let engine = AudioEngine()
        let db = try await Database(location: .inMemory)
        let player = QueuePlayer(engine: engine, database: db)

        let repo = TrackRepository(database: db)
        let ids = try await insertTestTracks(repo: repo, count: 2)

        // Seed the queue with current = index 0.
        try await player.addToQueue(ids)
        let initial = await player.queue.items
        await player.queue.replace(with: initial, startAt: 0)

        // Both flags set simultaneously — the spec gotcha is that
        // stop-after-current must win and the .one re-seek must not happen.
        await player.setRepeat(.one)
        await player.setStopAfterCurrent(true)

        // Capture the first emitted state from QueuePlayer.state.
        async let observedEnded: Bool = {
            for await s in player.state {
                if case .ended = s { return true }
                // Anything other than .ended (e.g. .loading on advance) means
                // we re-seeked or advanced — that's the failure case.
                return false
            }
            return false
        }()

        await player.handleTrackEnded()

        let sawEnded = await observedEnded
        #expect(sawEnded == true, "Expected .ended; got a different state — repeat-one re-seeked or advance fired")

        // Stop-after-current must be cleared (one-shot).
        let stopFlag = await player.queue.stopAfterCurrent
        #expect(stopFlag == false)

        // Current index preserved — no .one re-seek, no .all advance.
        let idx = await player.queue.currentIndex
        #expect(idx == 0)

        // Repeat-one mode is preserved (not cleared by stop).
        let mode = await player.queue.repeatMode
        #expect(mode == .one)
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
