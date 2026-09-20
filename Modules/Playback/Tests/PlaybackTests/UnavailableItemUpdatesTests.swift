import AudioEngine
import Foundation
import Persistence
import Testing
@testable import Playback

// MARK: - UnavailableItemUpdatesTests

/// #545: the unavailable-items set was published on one shared `AsyncStream`.
/// The queue view lives in the main window and the immersive window at the
/// same time, so two iterators divided the elements between them and one
/// window kept a stale set; and because cancelling the iterating task
/// terminates an `AsyncStream`, the first time the view went away the stream
/// ended for every later subscriber too.
@Suite("QueuePlayer unavailable-item updates (#545)")
struct UnavailableItemUpdatesTests {
    private func makePlayer() async throws -> QueuePlayer {
        let database = try await Database(location: .inMemory)
        return QueuePlayer(engine: AudioEngine(), database: database)
    }

    /// Collects the sets one subscriber sees.
    private actor Collector {
        private(set) var received: [Set<QueueItem.ID>] = []
        private var task: Task<Void, Never>?

        func start(_ stream: AsyncStream<Set<QueueItem.ID>>) {
            self.task = Task { [weak self] in
                for await ids in stream {
                    await self?.append(ids)
                }
            }
        }

        private func append(_ ids: Set<QueueItem.ID>) {
            self.received.append(ids)
        }

        func stop() {
            self.task?.cancel()
            self.task = nil
        }

        func wait(forAtLeast count: Int, timeout: Duration = .seconds(2)) async -> [Set<QueueItem.ID>] {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while ContinuousClock.now < deadline, self.received.count < count {
                try? await Task.sleep(for: .milliseconds(20))
            }
            return self.received
        }
    }

    @Test("a subscriber is handed the current set straight away")
    func currentSetArrivesFirst() async throws {
        let player = try await makePlayer()
        let collector = Collector()
        await collector.start(player.unavailableItemUpdates())
        defer { Task { await collector.stop() } }

        let received = await collector.wait(forAtLeast: 1)
        #expect(received.first == [], "a fresh player has nothing missing")
    }

    @Test("two subscribers both receive the same set, rather than dividing it")
    func twoSubscribersBothReceive() async throws {
        let player = try await makePlayer()
        let main = Collector()
        let immersive = Collector()
        await main.start(player.unavailableItemUpdates())
        await immersive.start(player.unavailableItemUpdates())
        defer {
            Task { await main.stop() }
            Task { await immersive.stop() }
        }

        // Two emissions each: the initial set, then this one.
        let missing: Set<QueueItem.ID> = [UUID(), UUID()]
        await player.emitUnavailableItems(missing)

        let mainSets = await main.wait(forAtLeast: 2)
        let immersiveSets = await immersive.wait(forAtLeast: 2)
        #expect(mainSets.last == missing, "the main window must see the set")
        #expect(immersiveSets.last == missing, "the second window must see the same set")
    }

    @Test("one subscriber going away leaves the other receiving")
    func teardownDoesNotEndTheOtherStream() async throws {
        let player = try await makePlayer()
        let leaving = Collector()
        let staying = Collector()
        await leaving.start(player.unavailableItemUpdates())
        await staying.start(player.unavailableItemUpdates())
        defer { Task { await staying.stop() } }

        _ = await leaving.wait(forAtLeast: 1)
        await leaving.stop() // SwiftUI cancels the .task when the view goes away
        try await Task.sleep(for: .milliseconds(100))

        let missing: Set<QueueItem.ID> = [UUID()]
        await player.emitUnavailableItems(missing)
        #expect(await staying.wait(forAtLeast: 2).last == missing)
    }

    @Test("a subscriber that joins after a teardown still receives")
    func laterSubscriberStillReceives() async throws {
        let player = try await makePlayer()
        let first = Collector()
        await first.start(player.unavailableItemUpdates())
        _ = await first.wait(forAtLeast: 1)
        await first.stop()
        try await Task.sleep(for: .milliseconds(100))

        // Re-entering Up Next subscribes again; the old code handed this one
        // an already-finished stream.
        let second = Collector()
        await second.start(player.unavailableItemUpdates())
        defer { Task { await second.stop() } }

        let missing: Set<QueueItem.ID> = [UUID()]
        await player.emitUnavailableItems(missing)
        #expect(await second.wait(forAtLeast: 2).last == missing)
    }

    @Test("a cancelled subscriber is dropped from the map")
    func cancelledSubscriberIsRemoved() async throws {
        let player = try await makePlayer()
        let collector = Collector()
        await collector.start(player.unavailableItemUpdates())
        _ = await collector.wait(forAtLeast: 1)
        #expect(await player.unavailableSubscriberCount == 1)

        await collector.stop()
        for _ in 0 ..< 100 where await player.unavailableSubscriberCount != 0 {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(await player.unavailableSubscriberCount == 0, "onTermination must unregister")
    }
}
