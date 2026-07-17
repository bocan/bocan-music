import Foundation
import Testing

// MARK: - PlaylistSortConventionTests

/// Source-convention checks for manual-playlist column sorting. The behaviour
/// lives in `View` bodies that can't be exercised host-less, so we assert the
/// structural facts that keep sorting working without corrupting the saved
/// manual order: the list is sortable, sorting is a temporary view sort over a
/// preserved baseline, drag-reorder is suspended while sorted, and a "Playlist
/// Order" control returns to the manual order.
@Suite("Playlist sort conventions")
struct PlaylistSortConventionTests {
    private func source(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("Detail view enables sorting and manual-order mode for manual playlists")
    func detailViewSortableAndManualOrder() throws {
        let source = try self.source("Sources/UI/Playlists/PlaylistDetailView.swift")
        #expect(source.contains("sortable: true"), "playlist track list must have clickable headers")
        #expect(
            source.contains("supportsManualOrder: self.vm.playlist?.kind == .manual"),
            "manual playlists must opt into manual-order mode so their saved order is the baseline"
        )
    }

    @Test("TracksView suspends reorder while sorted and offers a Playlist Order reset")
    func tracksViewManualOrderWiring() throws {
        let source = try self.source("Sources/UI/Browse/TracksView.swift")
        #expect(
            source.contains("effectiveOnMove"),
            "reorder must route through effectiveOnMove so it can be suspended while sorted"
        )
        #expect(
            source.contains("self.sortOrder.isEmpty ? self.onMove : nil"),
            "reorder must be nil while a temporary column sort is active"
        )
        #expect(source.contains("restoreManualOrder"), "clearing the sort must restore the manual order")
        #expect(
            source.contains("L10n.string(\"Playlist Order\")"),
            "a Playlist Order control must return to the manual order"
        )
    }
}
