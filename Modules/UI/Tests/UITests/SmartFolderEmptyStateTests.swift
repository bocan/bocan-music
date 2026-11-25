import Foundation
import Testing
@testable import UI

// MARK: - SmartFolderEmptyStateTests

/// An empty smart folder says nothing is in its window instead of telling a
/// user with music to add a music folder (#716). The choice is a pure
/// function; the wiring into the views is pinned by source convention,
/// because host-less tests cannot render them.
@Suite("Smart folder empty state (#716)")
struct SmartFolderEmptyStateTests {
    @Test("each smart folder has its own empty state", arguments: [
        SidebarDestination.recentlyAdded, .recentlyPlayed, .mostPlayed,
    ])
    func smartFoldersHaveContent(_ destination: SidebarDestination) throws {
        let content = try #require(EmptyStateContent.smartFolder(destination))
        #expect(!content.title.isEmpty)
        #expect(!content.message.isEmpty)
    }

    @Test("library destinations keep the empty-library state", arguments: [
        SidebarDestination.songs, .albums, .artists, .genres, .history, .playlist(1),
    ])
    func otherDestinationsKeepDefault(_ destination: SidebarDestination) {
        #expect(EmptyStateContent.smartFolder(destination) == nil)
    }

    @Test("the three empty states differ, and the symbols match the sidebar")
    func distinctContent() throws {
        let added = try #require(EmptyStateContent.smartFolder(.recentlyAdded))
        let played = try #require(EmptyStateContent.smartFolder(.recentlyPlayed))
        let most = try #require(EmptyStateContent.smartFolder(.mostPlayed))
        #expect(Set([added.title, played.title, most.title]).count == 3)
        #expect([added.symbol, played.symbol, most.symbol] == ["clock", "clock.arrow.circlepath", "chart.bar"])
    }

    @Test("the messages name the real windows")
    func windowsInMessages() throws {
        let added = try #require(EmptyStateContent.smartFolder(.recentlyAdded))
        let played = try #require(EmptyStateContent.smartFolder(.recentlyPlayed))
        #expect(added.message.contains(String(RecentlyAddedView.windowDays)))
        #expect(played.message.contains(String(SmartFolderView.recentlyPlayedDays)))
    }

    // MARK: Wiring

    private func source(_ relativePath: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("both Recently Added modes and the song smart folders pass their empty state", arguments: [
        ("Sources/UI/Browse/SmartFolders.swift", "emptyState: EmptyStateContent.smartFolder(self.destination)"),
        ("Sources/UI/Browse/RecentlyAddedView.swift", "emptyState: EmptyStateContent.smartFolder(.recentlyAdded)"),
    ])
    func smartFoldersPassContent(_ path: String, _ call: String) throws {
        #expect(try self.source(path).contains(call))
    }

    @Test("songs and albums fall back to Add Music Folder without a custom state", arguments: [
        "Sources/UI/Browse/TracksView.swift",
        "Sources/UI/Browse/AlbumsGridView.swift",
    ])
    func defaultStaysAddMusicFolder(_ path: String) throws {
        let source = try self.source(path)
        let custom = try #require(source.range(of: "} else if let emptyState = self.emptyState {"))
        let addFolder = try #require(source.range(of: "L10n.string(\"Add Music Folder\")"))
        #expect(custom.lowerBound < addFolder.lowerBound, "the custom state is checked before the default")
    }
}
