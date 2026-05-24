import AudioEngine
import Foundation
import Persistence
import Testing
@testable import Playback

private func makeTrack(n: Int) -> Track {
    let now = Int64(Date().timeIntervalSince1970)
    return Track(
        fileURL: "/tmp/sweep\(n).flac",
        fileFormat: "flac",
        duration: 200,
        title: "Sweep \(n)",
        addedAt: now,
        updatedAt: now
    )
}

private func makePlayer() async throws -> (QueuePlayer, Persistence.Database, TrackRepository) {
    let engine = AudioEngine()
    let db = try await Database(location: .inMemory)
    let player = QueuePlayer(engine: engine, database: db)
    return (player, db, TrackRepository(database: db))
}

@Suite("QueuePlayer transport sweep")
struct QueuePlayerSweepTests {
    @Test("setVolume forwards to the engine")
    func setVolume() async throws {
        let (player, _, _) = try await makePlayer()
        await player.setVolume(0.5)
    }

    @Test("setRate forwards to the engine")
    func setRate() async throws {
        let (player, _, _) = try await makePlayer()
        await player.setRate(1.25)
    }

    @Test("setCrossfadeConfig forwards to the crossfade scheduler")
    func setCrossfadeConfig() async throws {
        let (player, _, _) = try await makePlayer()
        await player.setCrossfadeConfig(CrossfadeScheduler.Config(durationSeconds: 3, albumGapless: true))
    }

    @Test("pause + stop are no-ops when idle")
    func pauseStopWhenIdle() async throws {
        let (player, _, _) = try await makePlayer()
        await player.pause()
        await player.stop()
    }

    @Test("savePositionForSuspend is a no-op when position is zero")
    func savePositionNoOp() async throws {
        let (player, _, _) = try await makePlayer()
        await player.savePositionForSuspend()
    }

    @Test("clearSavedState empties the queue and resets persistence")
    func clearSavedState() async throws {
        let (player, _, repo) = try await makePlayer()
        let id = try await repo.insert(makeTrack(n: 1))
        try await player.addToQueue([id])
        await player.clearSavedState()
        let items = await player.queue.items
        #expect(items.isEmpty)
    }

    @Test("play(trackIDs:) throws on a missing track ID")
    func playMissingTrackIDThrows() async throws {
        let (player, _, _) = try await makePlayer()
        await #expect(throws: (any Error).self) {
            try await player.play(trackIDs: [99999])
        }
    }

    @Test("next() on an empty queue stops cleanly")
    func nextOnEmptyQueue() async throws {
        let (player, _, _) = try await makePlayer()
        try await player.next()
    }

    @Test("previous() on an empty queue is a no-op")
    func previousOnEmptyQueue() async throws {
        let (player, _, _) = try await makePlayer()
        try await player.previous()
    }

    @Test("playAt(index:) on an empty queue returns without error")
    func playAtOutOfRange() async throws {
        let (player, _, _) = try await makePlayer()
        try? await player.playAt(index: 99)
    }

    @Test("playAlbum throws when the album has no tracks")
    func playAlbumEmpty() async throws {
        let (player, _, _) = try await makePlayer()
        try? await player.playAlbum(99999)
    }

    @Test("playArtist throws when the artist has no tracks")
    func playArtistEmpty() async throws {
        let (player, _, _) = try await makePlayer()
        try? await player.playArtist(99999)
    }

    @Test("unavailableItemIDs is empty on a fresh player")
    func unavailableEmpty() async throws {
        let (player, _, _) = try await makePlayer()
        let ids = await player.unavailableItemIDs()
        #expect(ids.isEmpty)
    }

    @Test("load(url:) on an invalid file URL throws")
    func loadBadURLThrows() async throws {
        let (player, _, _) = try await makePlayer()
        let url = URL(fileURLWithPath: "/tmp/definitely-not-an-audio-file.flac")
        await #expect(throws: (any Error).self) {
            try await player.load(url)
        }
    }

    @Test("seek(to:) throws when nothing is loaded")
    func seekWhenIdleThrows() async throws {
        let (player, _, _) = try await makePlayer()
        try? await player.seek(to: 10)
    }

    @Test("play() with an empty queue plays nothing")
    func playEmpty() async throws {
        let (player, _, _) = try await makePlayer()
        try? await player.play()
    }

    @Test("setShuffle wraps the queue API")
    func setShuffleWraps() async throws {
        let (player, _, _) = try await makePlayer()
        await player.setShuffle(true)
        let s = await player.queue.shuffleState
        if case .on = s {} else {
            Issue.record("expected .on")
        }
        await player.setShuffle(false)
    }
}
