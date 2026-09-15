import Foundation
import Testing
@testable import UI

// MARK: - AddToPlaylistRefreshConventionTests

/// The context menu's "Add to Playlist" wrote straight to the service and left
/// the sidebar holding its old snapshot, so the count badge next to the
/// playlist kept the number it had before the tracks arrived. The drop target
/// goes through the view model, which reloads, which is why dragging updated
/// the badge and the menu did not.
///
/// The action is a closure inside a SwiftUI view, so the guard reads source.
@Suite("Add to Playlist refreshes the sidebar")
struct AddToPlaylistRefreshConventionTests {
    private func source(_ relativePath: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI")
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("the menu action reloads the sidebar after the tracks land")
    func actionReloadsSidebar() throws {
        let actions = try self.source("Browse/TracksView+Actions.swift")
        let addToPlaylist = try #require(
            actions.range(of: "addToPlaylist:").map { actions[$0.lowerBound...] },
            "the addToPlaylist action is gone; this guard needs rewriting"
        )
        let block = String(addToPlaylist.prefix(900))
        #expect(block.contains("playlistService.addTracks"))
        #expect(
            block.contains("playlistSidebar.reload()"),
            "adding tracks must refresh the sidebar or its count badge goes stale"
        )
    }

    @Test("the drop target still goes through the view model, which reloads for itself")
    func dropTargetUsesTheViewModel() throws {
        let row = try self.source("Playlists/PlaylistRow.swift")
        #expect(row.contains("vm.addTracks("))
    }
}
