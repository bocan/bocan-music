import Foundation
import Testing

// MARK: - RecentlyAddedConventionTests

/// Source conventions for Recently Added's Songs / Albums switch (#700) that a
/// host-less test cannot see: the routing, the persisted key and the toolbar.
@Suite("Recently Added conventions")
struct RecentlyAddedConventionTests {
    private func source(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/\(relativePath)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("The content pane routes Recently Added to its own view with a persisted mode, default Songs")
    func contentPaneRoutesRecentlyAdded() throws {
        let pane = try self.source("AppRoot/ContentPane.swift")
        #expect(pane
            .contains("@AppStorage(\"recentlyAdded.detailMode\") private var recentlyAddedDetailMode: CollectionDetailMode = .songs"))
        #expect(pane.contains("RecentlyAddedView(mode: self.$recentlyAddedDetailMode, library: self.vm)"))
        #expect(pane.contains("case .recentlyPlayed, .mostPlayed:"), "the other smart folders keep the plain list")
    }

    @Test("The Songs / Albums switch is always in the toolbar, outside the mode branch")
    func toggleSurvivesOverflow() throws {
        let view = try self.source("Browse/RecentlyAddedView.swift")
        let branch = try #require(view.range(of: "if self.mode == .albums"))
        let toolbar = try #require(view.range(of: ".toolbar {"))
        let toggle = try #require(view.range(of: "CollectionDetailModeToggle(mode: self.$mode)"))
        // docs/GOTCHAS.md: a toolbar item wrapped in `if` drops out of the overflow menu.
        #expect(branch.lowerBound < toolbar.lowerBound && toolbar.lowerBound < toggle.lowerBound)
    }

    @Test("Albums mode uses its own view model and sort key, newest first")
    func albumsModeOwnsItsSort() throws {
        let view = try self.source("Browse/RecentlyAddedView.swift")
        #expect(view.contains("sortOrderKey: AlbumsViewModel.recentlyAddedSortOrderKey"))
        #expect(view.contains("defaultSortOrder: .dateAdded"))
        #expect(view.contains("@StateObject private var albumsVM"))
    }
}
