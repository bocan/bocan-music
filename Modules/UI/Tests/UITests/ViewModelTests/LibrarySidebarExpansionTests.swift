import Foundation
import Persistence
import Testing
@testable import UI

// MARK: - LibrarySidebarExpansionTests

/// Phase 19 step 9: `LibraryViewModel.sectionExpansion` survives a
/// `saveUIState` / `restoreUIState` round-trip through the settings table.
@Suite("LibraryViewModel Sidebar Expansion")
@MainActor
struct LibrarySidebarExpansionTests {
    private func makeVM() async throws -> (LibraryViewModel, Database) {
        let db = try await Database(location: .inMemory)
        return (LibraryViewModel(database: db, engine: MockTransport()), db)
    }

    @Test("Section expansion defaults to all sections open and no servers")
    func defaultsOnFreshInstall() async throws {
        let (vm, _) = try await self.makeVM()
        #expect(vm.sectionExpansion == SidebarSectionExpansion())
        #expect(vm.subsonicServers.isEmpty)
    }

    @Test("saveUIState then restoreUIState preserves sectionExpansion")
    func roundTripThroughSettings() async throws {
        let (vm, db) = try await self.makeVM()
        let serverID = UUID()
        vm.sectionExpansion = SidebarSectionExpansion(
            localLibrary: false,
            sources: false,
            recents: true,
            queue: false,
            expandedServers: [serverID]
        )
        await vm.saveUIState()

        let vm2 = LibraryViewModel(database: db, engine: MockTransport())
        await vm2.restoreUIState()
        #expect(vm2.sectionExpansion.localLibrary == false)
        #expect(vm2.sectionExpansion.sources == false)
        #expect(vm2.sectionExpansion.recents == true)
        #expect(vm2.sectionExpansion.queue == false)
        #expect(vm2.sectionExpansion.expandedServers == [serverID])
    }

    @Test("reloadSubsonicServers is a no-op without a listing")
    func reloadWithoutListing() async throws {
        let (vm, _) = try await self.makeVM()
        await vm.reloadSubsonicServers()
        #expect(vm.subsonicServers.isEmpty)
    }

    @Test("reloadSubsonicServers populates from an injected listing")
    func reloadWithListing() async throws {
        let db = try await Database(location: .inMemory)
        let serverA = SubsonicSidebarServer(id: UUID(), name: "Home", sortIndex: 0)
        let serverB = SubsonicSidebarServer(id: UUID(), name: "Lab", sortIndex: 1)
        let listing = StubListing(servers: [serverA, serverB])
        let vm = LibraryViewModel(
            database: db,
            engine: MockTransport(),
            subsonicSidebarListing: listing
        )
        await vm.reloadSubsonicServers()
        #expect(vm.subsonicServers == [serverA, serverB])
    }

    @Test("setSubsonicServerSidebarVisible(false) hides the server and reloads")
    func setSidebarVisibleHidesServer() async throws {
        let db = try await Database(location: .inMemory)
        let visibleID = UUID()
        let visible = SubsonicSidebarServer(id: visibleID, name: "Lab", sortIndex: 0)
        let listing = MutableStubListing(servers: [visible])
        let vm = LibraryViewModel(
            database: db,
            engine: MockTransport(),
            subsonicSidebarListing: listing
        )
        await vm.reloadSubsonicServers()
        #expect(vm.subsonicServers == [visible])

        await vm.setSubsonicServerSidebarVisible(id: visibleID, visible: false)

        #expect(listing.lastSetSidebarVisibleCall?.id == visibleID)
        #expect(listing.lastSetSidebarVisibleCall?.visible == false)
        #expect(vm.subsonicServers.isEmpty)
    }

    @Test("setSubsonicServerSidebarVisible(true) re-enables a hidden server and refreshes both lists")
    func setSidebarVisibleRestoresHiddenServer() async throws {
        let db = try await Database(location: .inMemory)
        let hiddenID = UUID()
        let hidden = SubsonicSidebarServer(id: hiddenID, name: "Hidden", sortIndex: 0)
        let listing = MutableStubListing(servers: [])
        listing.hiddenServers = [hidden]
        let vm = LibraryViewModel(
            database: db,
            engine: MockTransport(),
            subsonicSidebarListing: listing
        )
        await vm.reloadSubsonicServers()
        #expect(vm.subsonicServers.isEmpty)
        #expect(vm.hiddenSubsonicServers == [hidden])

        await vm.setSubsonicServerSidebarVisible(id: hiddenID, visible: true)

        #expect(listing.lastSetSidebarVisibleCall?.id == hiddenID)
        #expect(listing.lastSetSidebarVisibleCall?.visible == true)
        #expect(vm.subsonicServers == [hidden])
        #expect(vm.hiddenSubsonicServers.isEmpty)
    }

    @Test("setSubsonicServerSidebarVisible is a no-op without a listing")
    func setSidebarVisibleWithoutListing() async throws {
        let (vm, _) = try await self.makeVM()
        await vm.setSubsonicServerSidebarVisible(id: UUID(), visible: false)
        #expect(vm.subsonicServers.isEmpty)
    }

    @Test("confirmRemoveSubsonicServer deletes the staged server and reloads (#306)")
    func confirmRemoveDeletesStagedServer() async throws {
        let db = try await Database(location: .inMemory)
        let id = UUID()
        let server = SubsonicSidebarServer(id: id, name: "Home", sortIndex: 0)
        let listing = MutableStubListing(servers: [server])
        let vm = LibraryViewModel(database: db, engine: MockTransport(), subsonicSidebarListing: listing)
        await vm.reloadSubsonicServers()
        #expect(vm.subsonicServers == [server])

        vm.subsonicServerPendingRemoval = server
        await vm.confirmRemoveSubsonicServer()

        #expect(listing.lastRemovedServerID == id)
        #expect(vm.subsonicServerPendingRemoval == nil, "pending state must clear after delete")
        #expect(vm.subsonicServers.isEmpty)
    }

    @Test("confirmRemoveSubsonicServer is a no-op when nothing is staged (#306)")
    func confirmRemoveNoOpWhenNothingStaged() async throws {
        let server = SubsonicSidebarServer(id: UUID(), name: "Home", sortIndex: 0)
        let listing = MutableStubListing(servers: [server])
        let db = try await Database(location: .inMemory)
        let vm = LibraryViewModel(database: db, engine: MockTransport(), subsonicSidebarListing: listing)
        await vm.reloadSubsonicServers()

        await vm.confirmRemoveSubsonicServer() // nothing staged
        #expect(listing.lastRemovedServerID == nil, "no delete should happen with nothing staged")
        #expect(vm.subsonicServers == [server])
    }

    @Test("Capability change events trigger a sidebar reload")
    func capabilityChangeReloadsSidebar() async throws {
        let db = try await Database(location: .inMemory)
        let serverID = UUID()
        let initial = SubsonicSidebarServer(id: serverID, name: "Lab", sortIndex: 0)
        let upgraded = SubsonicSidebarServer(
            id: serverID,
            name: "Lab",
            sortIndex: 0,
            supportsPodcasts: true
        )
        let listing = MutableStubListing(servers: [initial])
        let observer = StubCapabilityObserver()

        let vm = LibraryViewModel(
            database: db,
            engine: MockTransport(),
            subsonicSidebarListing: listing,
            subsonicCapabilityObserver: observer
        )
        await vm.reloadSubsonicServers()
        #expect(vm.subsonicServers == [initial])

        // Simulate a server upgrade unlocking Podcasts.
        listing.servers = [upgraded]
        observer.emit(serverID)

        // Wait for the observer task to deliver the reload.
        try await pollUntil(timeout: 1.0) { vm.subsonicServers == [upgraded] }
        #expect(vm.subsonicServers == [upgraded])
    }
}

// MARK: - Polling helper

@MainActor
private func pollUntil(timeout: TimeInterval, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}

// MARK: - StubListing

private struct StubListing: SubsonicSidebarListing {
    let servers: [SubsonicSidebarServer]

    func fetchSidebarServers() async throws -> [SubsonicSidebarServer] {
        self.servers
    }

    func fetchHiddenSidebarServers() async throws -> [SubsonicSidebarServer] {
        []
    }

    func setSidebarVisible(id _: UUID, visible _: Bool) async throws {}

    func removeServer(id _: UUID) async throws {}
}

// MARK: - MutableStubListing

/// Mutable variant whose return value can change across calls so the reload
/// path actually observes a new snapshot after a capability event.
private final class MutableStubListing: SubsonicSidebarListing, @unchecked Sendable {
    var servers: [SubsonicSidebarServer]
    var hiddenServers: [SubsonicSidebarServer] = []
    private(set) var lastSetSidebarVisibleCall: (id: UUID, visible: Bool)?
    private(set) var lastRemovedServerID: UUID?

    init(servers: [SubsonicSidebarServer]) {
        self.servers = servers
    }

    func fetchSidebarServers() async throws -> [SubsonicSidebarServer] {
        self.servers
    }

    func fetchHiddenSidebarServers() async throws -> [SubsonicSidebarServer] {
        self.hiddenServers
    }

    func setSidebarVisible(id: UUID, visible: Bool) async throws {
        self.lastSetSidebarVisibleCall = (id, visible)
        if visible {
            if let restored = self.hiddenServers.first(where: { $0.id == id }) {
                self.hiddenServers.removeAll { $0.id == id }
                self.servers.append(restored)
            }
        } else {
            if let removed = self.servers.first(where: { $0.id == id }) {
                self.servers.removeAll { $0.id == id }
                self.hiddenServers.append(removed)
            }
        }
    }

    func removeServer(id: UUID) async throws {
        self.lastRemovedServerID = id
        self.servers.removeAll { $0.id == id }
        self.hiddenServers.removeAll { $0.id == id }
    }
}

// MARK: - StubCapabilityObserver

private final class StubCapabilityObserver: SubsonicCapabilityChangeObserving, @unchecked Sendable {
    private let (stream, continuation) = AsyncStream<UUID>.makeStream()

    func capabilityChanges() -> AsyncStream<UUID> {
        self.stream
    }

    func emit(_ id: UUID) {
        self.continuation.yield(id)
    }
}
