import Foundation
import Library
import Persistence
import Testing
@testable import UI

// MARK: - NewPlaylistSelectionTests (#535)

/// Creating a playlist used to leave the sidebar selection where it was, so
/// the new row had to be found by hand. The sidebar recorded the new id and
/// nothing read it.
@Suite("A new playlist is selected")
@MainActor
struct NewPlaylistSelectionTests {
    private func makeVM() async throws -> LibraryViewModel {
        let db = try await Database(location: .inMemory)
        return LibraryViewModel(database: db, engine: MockTransport())
    }

    private func waitForDestination(_ vm: LibraryViewModel, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if case .playlist = vm.selectedDestination {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @Test("creating a playlist navigates to it")
    func createSelectsTheNewPlaylist() async throws {
        let vm = try await self.makeVM()
        let newID = await vm.playlistSidebar.createPlaylist(name: "Road Trip")
        let id = try #require(newID)
        await self.waitForDestination(vm)

        #expect(vm.selectedDestination == .playlist(id))
    }

    @Test("the playlist it navigates to is the one just made")
    func secondCreateMovesOn() async throws {
        let vm = try await self.makeVM()
        _ = await vm.playlistSidebar.createPlaylist(name: "First")
        await self.waitForDestination(vm)

        let second = try #require(await vm.playlistSidebar.createPlaylist(name: "Second"))
        let deadline = Date().addingTimeInterval(5)
        while vm.selectedDestination != .playlist(second), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(vm.selectedDestination == .playlist(second))
    }

    @Test("a failed create navigates nowhere")
    func failedCreateLeavesTheDestination() async throws {
        let vm = try await self.makeVM()
        let before = vm.selectedDestination

        // An empty name is refused by the service.
        _ = await vm.playlistSidebar.createPlaylist(name: "   ")
        try await Task.sleep(nanoseconds: 200_000_000)

        #expect(vm.selectedDestination == before)
        #expect(vm.playlistSidebar.lastError != nil)
    }
}
