import Foundation
import Testing
@testable import UI

// MARK: - Doubles

/// A scripted sidebar listing: two servers shown, one hidden.
private actor StubListing: JellyfinSidebarListing {
    private(set) var shown: [JellyfinSidebarServer]
    private(set) var hidden: [JellyfinSidebarServer]
    private(set) var removed: [UUID] = []
    var failRemoval = false

    init(shown: [JellyfinSidebarServer], hidden: [JellyfinSidebarServer] = []) {
        self.shown = shown
        self.hidden = hidden
    }

    func fetchSidebarServers() async throws -> [JellyfinSidebarServer] {
        self.shown
    }

    func fetchHiddenSidebarServers() async throws -> [JellyfinSidebarServer] {
        self.hidden
    }

    func setSidebarVisible(id: UUID, visible: Bool) async throws {
        if visible, let index = self.hidden.firstIndex(where: { $0.id == id }) {
            self.shown.append(self.hidden.remove(at: index))
        } else if !visible, let index = self.shown.firstIndex(where: { $0.id == id }) {
            self.hidden.append(self.shown.remove(at: index))
        }
    }

    func removeServer(id: UUID) async throws {
        if self.failRemoval {
            throw StubError.refused
        }
        self.removed.append(id)
        self.shown.removeAll { $0.id == id }
        self.hidden.removeAll { $0.id == id }
    }

    func setFailRemoval(_ value: Bool) {
        self.failRemoval = value
    }

    enum StubError: Error { case refused }
}

private struct StubObserver: JellyfinConnectionObserving {
    let snapshot: [UUID: SubsonicSidebarConnectionState]
    let updates: AsyncStream<(UUID, SubsonicSidebarConnectionState)>
    let retries: Locked<[UUID]>

    func currentStates() async -> [UUID: SubsonicSidebarConnectionState] {
        self.snapshot
    }

    func stateUpdates() -> AsyncStream<(UUID, SubsonicSidebarConnectionState)> {
        self.updates
    }

    func retry(serverID: UUID) async {
        self.retries.update { $0.append(serverID) }
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        self.stored = value
    }

    var value: Value {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.stored
    }

    func update(_ body: (inout Value) -> Void) {
        self.lock.lock()
        defer { self.lock.unlock() }
        body(&self.stored)
    }
}

private func server(_ name: String, index: Int) -> JellyfinSidebarServer {
    JellyfinSidebarServer(id: UUID(), name: name, sortIndex: index)
}

// MARK: - Tests

@Suite("JellyfinSourceModel")
@MainActor
struct JellyfinSourceModelTests {
    @Test("a model with nothing wired in is empty and every call is a no-op")
    func unwired() async {
        let model = JellyfinSourceModel()
        await model.reloadServers()
        await model.setServerSidebarVisible(id: UUID(), visible: false)
        await model.retryConnection(serverID: UUID())
        #expect(model.servers.isEmpty)
        #expect(!model.hasServers)
    }

    @Test("reload fills the shown and the hidden list, and hasServers counts both")
    func reload() async {
        let hiddenOnly = JellyfinSourceModel(listing: StubListing(shown: [], hidden: [server("Hidden", index: 0)]))
        await hiddenOnly.reloadServers()
        #expect(hiddenOnly.servers.isEmpty)
        #expect(hiddenOnly.hiddenServers.map(\.name) == ["Hidden"])
        #expect(hiddenOnly.hasServers, "a hidden server still counts as a source")

        let both = JellyfinSourceModel(listing: StubListing(
            shown: [server("A", index: 0), server("B", index: 1)],
            hidden: [server("C", index: 2)]
        ))
        await both.reloadServers()
        #expect(both.servers.map(\.name) == ["A", "B"])
        #expect(both.hiddenServers.map(\.name) == ["C"])
    }

    @Test("hiding a server moves it to the hidden list; showing it moves it back")
    func visibility() async {
        let alpha = server("A", index: 0)
        let model = JellyfinSourceModel(listing: StubListing(shown: [alpha]))
        await model.reloadServers()
        await model.setServerSidebarVisible(id: alpha.id, visible: false)
        #expect(model.servers.isEmpty)
        #expect(model.hiddenServers.map(\.id) == [alpha.id])
        await model.setServerSidebarVisible(id: alpha.id, visible: true)
        #expect(model.servers.map(\.id) == [alpha.id])
        #expect(model.hiddenServers.isEmpty)
    }

    @Test("confirming a removal removes the staged server, clears the staging and drops its status")
    func removal() async {
        let alpha = server("A", index: 0)
        let beta = server("B", index: 1)
        let listing = StubListing(shown: [alpha, beta])
        let model = JellyfinSourceModel(listing: listing)
        await model.reloadServers()
        model.serverPendingRemoval = alpha
        await model.confirmRemoveServer()
        #expect(model.serverPendingRemoval == nil)
        #expect(model.servers.map(\.id) == [beta.id])
        #expect(await listing.removed == [alpha.id])
    }

    @Test("a failed removal clears the staging and keeps the server in the list")
    func failedRemoval() async {
        let alpha = server("A", index: 0)
        let listing = StubListing(shown: [alpha])
        await listing.setFailRemoval(true)
        let model = JellyfinSourceModel(listing: listing)
        await model.reloadServers()
        model.serverPendingRemoval = alpha
        await model.confirmRemoveServer()
        #expect(model.serverPendingRemoval == nil)
        #expect(model.servers.map(\.id) == [alpha.id])
    }

    @Test("confirming with nothing staged removes nothing")
    func nothingStaged() async {
        let listing = StubListing(shown: [server("A", index: 0)])
        let model = JellyfinSourceModel(listing: listing)
        await model.confirmRemoveServer()
        #expect(await listing.removed.isEmpty)
    }

    @Test("connection states start from the snapshot and follow the updates; retry reaches the observer")
    func connectionStates() async {
        let id = UUID()
        var continuation: AsyncStream<(UUID, SubsonicSidebarConnectionState)>.Continuation?
        let updates = AsyncStream<(UUID, SubsonicSidebarConnectionState)> { continuation = $0 }
        let retries = Locked<[UUID]>([])
        let model = JellyfinSourceModel(
            listing: nil,
            connectionObserver: StubObserver(snapshot: [id: .connecting], updates: updates, retries: retries)
        )
        #expect(await self.waitUntil { model.connectionStates[id] == .connecting })
        continuation?.yield((id, .online))
        #expect(await self.waitUntil { model.connectionStates[id] == .online })
        await model.retryConnection(serverID: id)
        #expect(retries.value == [id])
        continuation?.finish()
    }

    @Test("bootstrap runs the closure the App layer set")
    func bootstrap() async {
        let ran = Locked(false)
        let model = JellyfinSourceModel()
        model.bootstrap = { ran.update { $0 = true } }
        await model.bootstrapServers()
        #expect(ran.value)
    }

    /// Polls the main actor until `condition` holds, so a stream update has landed.
    private func waitUntil(timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() {
                return true
            }
            do {
                try await Task.sleep(for: .milliseconds(5))
            } catch {
                return condition()
            }
        }
        return condition()
    }
}
