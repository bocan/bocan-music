import AppKit
import Foundation
import Persistence
import Testing
@testable import UI

// MARK: - NavigationInputTests (#378)

/// Pins the browser-style navigation inputs: the pure eligibility tables of
/// `NavigationInputMonitor` plus the structural parent map Esc drills out
/// along, and the source-convention wiring in `RootView`.
@Suite("Navigation input")
struct NavigationInputTests {
    // MARK: - Mouse buttons

    @Test("thumb buttons 3 and 4 map to history back and forward")
    func buttonMapping() {
        #expect(NavigationInputMonitor.historyDirection(forButtonNumber: 3) == .back)
        #expect(NavigationInputMonitor.historyDirection(forButtonNumber: 4) == .forward)
    }

    @Test("left, right, middle, and exotic buttons pass through")
    func otherButtonsPassThrough() {
        for number in [0, 1, 2, 5, 27] {
            #expect(NavigationInputMonitor.historyDirection(forButtonNumber: number) == nil)
        }
    }

    // MARK: - Esc eligibility

    @Test("a bare Esc is eligible; chords and other keys are not")
    func escEligibility() {
        #expect(NavigationInputMonitor.isBareEscape(keyCode: 53, modifiers: []))
        #expect(!NavigationInputMonitor.isBareEscape(keyCode: 53, modifiers: [.command]))
        #expect(!NavigationInputMonitor.isBareEscape(keyCode: 53, modifiers: [.option]))
        #expect(!NavigationInputMonitor.isBareEscape(keyCode: 49, modifiers: []), "space is not Esc")
    }

    // MARK: - Structural parents

    @Test("drill-downs map to their section roots")
    func drillDownParents() {
        let serverID = UUID()
        #expect(LibraryViewModel.parentDestination(of: .artist(7)) == .artists)
        #expect(LibraryViewModel.parentDestination(of: .album(7)) == .albums)
        #expect(LibraryViewModel.parentDestination(of: .genre("Ambient")) == .genres)
        #expect(LibraryViewModel.parentDestination(of: .composer("Eno")) == .composers)
        #expect(LibraryViewModel.parentDestination(of: .podcastShow(3)) == .podcasts)
        #expect(
            LibraryViewModel.parentDestination(of: .subsonicArtist(serverID, "ar-1"))
                == .subsonicArtists(serverID)
        )
        #expect(
            LibraryViewModel.parentDestination(of: .subsonicAlbum(serverID, "al-1"))
                == .subsonicAlbums(serverID)
        )
        #expect(
            LibraryViewModel.parentDestination(of: .subsonicPlaylist(serverID, "pl-1"))
                == .subsonicPlaylists(serverID)
        )
    }

    @Test("section roots and underivable destinations have no parent")
    func rootsHaveNoParent() {
        for destination: SidebarDestination in [
            .songs, .albums, .artists, .genres, .composers, .podcasts,
            .radio, .upNext, .recentlyAdded, .folder(1), .playlist(2), .search("x"),
        ] {
            #expect(
                LibraryViewModel.parentDestination(of: destination) == nil,
                "\(destination) must not drill out"
            )
        }
    }

    // MARK: - Plausible containers

    @Test("an album's plausible containers are its artist, genre, composer, and the Albums root")
    func albumContainers() {
        #expect(LibraryViewModel.isPlausibleContainer(.artist(3), of: .album(7)))
        #expect(LibraryViewModel.isPlausibleContainer(.genre("Ambient"), of: .album(7)))
        #expect(LibraryViewModel.isPlausibleContainer(.composer("Eno"), of: .album(7)))
        #expect(LibraryViewModel.isPlausibleContainer(.albums, of: .album(7)))
        #expect(!LibraryViewModel.isPlausibleContainer(.podcasts, of: .album(7)))
        #expect(!LibraryViewModel.isPlausibleContainer(.radio, of: .album(7)))
        #expect(!LibraryViewModel.isPlausibleContainer(.songs, of: .album(7)))
    }

    @Test("Subsonic containers must match the server")
    func subsonicContainersMatchServer() {
        let server = UUID()
        let other = UUID()
        #expect(LibraryViewModel.isPlausibleContainer(
            .subsonicArtist(server, "ar-1"), of: .subsonicAlbum(server, "al-1")
        ))
        #expect(LibraryViewModel.isPlausibleContainer(
            .subsonicAlbums(server), of: .subsonicAlbum(server, "al-1")
        ))
        #expect(!LibraryViewModel.isPlausibleContainer(
            .subsonicAlbums(other), of: .subsonicAlbum(server, "al-1")
        ))
    }

    // MARK: - Drill-out behaviour

    @MainActor
    private func makeVM() async throws -> LibraryViewModel {
        let db = try await Database(location: .inMemory)
        return LibraryViewModel(database: db, engine: MockTransport())
    }

    @MainActor
    private func awaitDestination(
        _ expected: SidebarDestination,
        on vm: LibraryViewModel
    ) async throws -> Bool {
        for _ in 0 ..< 100 {
            if vm.selectedDestination == expected { return true }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    @MainActor
    @Test("Esc from an album reached via its artist returns to that artist, then to Artists")
    func albumFromArtistDrillsOutToArtist() async throws {
        let vm = try await self.makeVM()
        await vm.selectDestination(.artists)
        await vm.selectDestination(.artist(3))
        await vm.selectDestination(.album(7))

        #expect(vm.drillOutToParent())
        #expect(try await self.awaitDestination(.artist(3), on: vm), "history parent must win")

        #expect(vm.drillOutToParent())
        #expect(try await self.awaitDestination(.artists, on: vm), "then the structural root")
    }

    @Test("Esc from an album reached from elsewhere falls back to the Albums root")
    @MainActor
    func albumFromElsewhereFallsBackToAlbums() async throws {
        let vm = try await self.makeVM()
        await vm.selectDestination(.podcasts)
        await vm.selectDestination(.album(7))

        #expect(vm.drillOutToParent())
        #expect(
            try await self.awaitDestination(.albums, on: vm),
            "an implausible history entry must not make Esc teleport to Podcasts"
        )
    }

    @Test("Esc at a section root clears an active search, then passes through")
    @MainActor
    func rootEscClearsSearch() async throws {
        let vm = try await self.makeVM()
        await vm.selectDestination(.songs)
        vm.searchQuery = "ulrich"

        #expect(vm.drillOutToParent(), "the filter is the last layer to peel")
        #expect(vm.searchQuery.isEmpty)

        #expect(!vm.drillOutToParent(), "nothing left: the event must pass through")
    }

    @Test("Esc from a drill-down prefers navigation over clearing the query")
    @MainActor
    func drillOutWinsOverClear() async throws {
        let vm = try await self.makeVM()
        await vm.selectDestination(.albums)
        await vm.selectDestination(.album(7))
        vm.searchQuery = "typed inside the detail"

        #expect(vm.drillOutToParent())
        #expect(
            try await self.awaitDestination(.albums, on: vm),
            "a drill-down must navigate out first, not silently eat the query"
        )
    }

    // MARK: - Wiring

    @Test("RootView attaches the navigation input monitor")
    func rootViewAttachesMonitor() throws {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/AppRoot/RootView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(
            source.contains("NavigationInputBackground"),
            "RootView must attach NavigationInputBackground (#378)"
        )
    }
}
