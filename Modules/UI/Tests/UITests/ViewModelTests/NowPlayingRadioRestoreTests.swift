import AudioEngine
import Foundation
import Playback
import Testing
@testable import Persistence
@testable import UI

// MARK: - NowPlayingRadioRestoreTests

/// Regression (ADR-079 flag, fixed in ADR-081): a restored queue whose
/// current item is a live stream is never engine-preloaded, so no
/// current-track change emits at launch and the now-playing display sat
/// on "Not playing" forever, with everything keyed off it (the strip,
/// the Clear Queue menu gate) wrong. The view model now seeds its
/// display once from the queue's current item after activation.
@Suite("Now-playing radio restore display")
struct NowPlayingRadioRestoreTests {
    @MainActor
    @Test("a restored radio current item populates the display without playback")
    func restoredRadioPopulatesDisplay() async throws {
        let db = try await Database(location: .inMemory)
        let player = QueuePlayer(engine: AudioEngine(), database: db)
        await player.waitUntilActivated()
        let url = try #require(URL(string: "http://127.0.0.1:9/never"))
        let item = QueueItem.makeInternetRadio(
            name: "Test FM",
            streamURL: url,
            homePage: nil
        )
        await player.queue.replace(with: [item], startAt: 0)

        let vm = NowPlayingViewModel(engine: player, database: db)
        let deadline = Date().addingTimeInterval(5)
        while vm.nowPlayingRadioStreamURL == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        #expect(vm.nowPlayingRadioStreamURL == url.absoluteString)
        #expect(vm.nowPlayingRadioStationName == "Test FM")
        #expect(vm.hasCurrentItem, "Clear Queue keys off hasCurrentItem")
        #expect(vm.nowPlayingTrackID == nil, "a stream is not a library track")
    }

    @MainActor
    @Test("a queue seeded after the view model exists still populates the display")
    func lateSeededRadioPopulatesDisplay() async throws {
        let db = try await Database(location: .inMemory)
        let player = QueuePlayer(engine: AudioEngine(), database: db)
        await player.waitUntilActivated()
        // View model first, queue second: the E2E seeder's ordering. The
        // queue-change observation (.reset) must sync the display because
        // no engine emission ever follows a replace at rest.
        let vm = NowPlayingViewModel(engine: player, database: db)
        try await Task.sleep(nanoseconds: 200_000_000) // let observers attach

        let url = try #require(URL(string: "http://127.0.0.1:9/never"))
        let item = QueueItem.makeInternetRadio(name: "Late FM", streamURL: url, homePage: nil)
        await player.queue.replace(with: [item], startAt: 0)

        let deadline = Date().addingTimeInterval(5)
        while vm.nowPlayingRadioStreamURL == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(vm.nowPlayingRadioStreamURL == url.absoluteString)
        #expect(vm.hasCurrentItem)

        // Clearing the queue at rest must clear the display the same way.
        await player.queue.clear()
        let clearDeadline = Date().addingTimeInterval(5)
        while vm.hasCurrentItem, Date() < clearDeadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        #expect(!vm.hasCurrentItem)
    }

    @MainActor
    @Test("an empty restored queue leaves the display cleared")
    func emptyQueueStaysCleared() async throws {
        let db = try await Database(location: .inMemory)
        let player = QueuePlayer(engine: AudioEngine(), database: db)
        await player.waitUntilActivated()

        let vm = NowPlayingViewModel(engine: player, database: db)
        // Give the initial sync a moment; it must not invent an item.
        try await Task.sleep(nanoseconds: 300_000_000)

        #expect(!vm.hasCurrentItem)
        #expect(vm.title.isEmpty)
    }
}
