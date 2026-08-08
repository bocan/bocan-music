import AppKit
import Foundation
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
