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
}

// MARK: - StubListing

private struct StubListing: SubsonicSidebarListing {
    let servers: [SubsonicSidebarServer]

    func fetchSidebarServers() async throws -> [SubsonicSidebarServer] {
        self.servers
    }
}
