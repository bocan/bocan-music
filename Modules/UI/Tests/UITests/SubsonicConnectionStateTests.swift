import Combine
import Foundation
import Persistence
import Testing
@testable import UI

// MARK: - Doubles

private struct StubSubsonicObserver: SubsonicConnectionObserving {
    let snapshot: [UUID: SubsonicSidebarConnectionState]
    let updates: AsyncStream<(UUID, SubsonicSidebarConnectionState)>

    func currentStates() async -> [UUID: SubsonicSidebarConnectionState] {
        self.snapshot
    }

    func stateUpdates() -> AsyncStream<(UUID, SubsonicSidebarConnectionState)> {
        self.updates
    }

    func retry(serverID: UUID) async {}
}

// MARK: - SubsonicConnectionStateTests

/// #693: the Subsonic monitor reports "online" after every 60 s ping, and
/// `LibraryViewModel` is the spine every window observes, so a repeated state
/// must not publish.
@Suite("Subsonic connection state (LibraryViewModel)")
@MainActor
struct SubsonicConnectionStateTests {
    @Test("an unchanged state from the 60 s ping does not publish, so the window does not redraw")
    func unchangedStateDoesNotPublish() async throws {
        let id = UUID()
        let sentinel = UUID()
        var continuation: AsyncStream<(UUID, SubsonicSidebarConnectionState)>.Continuation?
        let updates = AsyncStream<(UUID, SubsonicSidebarConnectionState)> { continuation = $0 }
        let vm = try await LibraryViewModel(
            database: Database(location: .inMemory),
            engine: MockTransport(),
            subsonicConnectionObserver: StubSubsonicObserver(snapshot: [:], updates: updates)
        )
        continuation?.yield((id, .online))
        #expect(await waitUntil { vm.subsonicConnectionStates[id] == .online })

        var publishes = 0
        let subscription = vm.$subsonicConnectionStates.dropFirst().sink { _ in publishes += 1 }
        for _ in 0 ..< 3 {
            continuation?.yield((id, .online))
        }
        // The stream is in order, so once the sentinel lands the repeats have too.
        continuation?.yield((sentinel, .online))
        #expect(await waitUntil { vm.subsonicConnectionStates[sentinel] == .online })
        #expect(publishes == 1, "only the sentinel's new state publishes")
        subscription.cancel()
        continuation?.finish()
    }

    @Test("a changed state still publishes")
    func changedStatePublishes() async throws {
        let id = UUID()
        var continuation: AsyncStream<(UUID, SubsonicSidebarConnectionState)>.Continuation?
        let updates = AsyncStream<(UUID, SubsonicSidebarConnectionState)> { continuation = $0 }
        let vm = try await LibraryViewModel(
            database: Database(location: .inMemory),
            engine: MockTransport(),
            subsonicConnectionObserver: StubSubsonicObserver(snapshot: [:], updates: updates)
        )
        continuation?.yield((id, .online))
        #expect(await waitUntil { vm.subsonicConnectionStates[id] == .online })
        continuation?.yield((id, .connecting))
        #expect(await waitUntil { vm.subsonicConnectionStates[id] == .connecting })
        continuation?.finish()
    }

    @Test("the snapshot fills a server with no state but never overwrites a newer update")
    func snapshotFillsOnlyMissingServers() async throws {
        let fresh = UUID()
        let fromSnapshot = UUID()
        var continuation: AsyncStream<(UUID, SubsonicSidebarConnectionState)>.Continuation?
        let updates = AsyncStream<(UUID, SubsonicSidebarConnectionState)> { continuation = $0 }
        // Queued before the view model reads the snapshot, so it is the newer fact.
        continuation?.yield((fresh, .online))
        let vm = try await LibraryViewModel(
            database: Database(location: .inMemory),
            engine: MockTransport(),
            subsonicConnectionObserver: StubSubsonicObserver(
                snapshot: [fresh: .connecting, fromSnapshot: .online],
                updates: updates
            )
        )
        #expect(await waitUntil {
            vm.subsonicConnectionStates[fresh] == .online && vm.subsonicConnectionStates[fromSnapshot] == .online
        })
        continuation?.finish()
    }
}
