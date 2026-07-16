import Foundation
import Testing

// MARK: - SmartPlaylistSortConventionTests

/// Source-convention checks for smart-playlist sorting. The behaviour lives in
/// `View` bodies that can't be exercised host-less, so we assert the structural
/// facts that keep both bugs fixed: the track list is sortable (clickable column
/// headers) and its rows are pushed through with `preserveOrder` so the smart
/// playlist's own SQL order is honoured rather than re-sorted away.
@Suite("Smart playlist sort conventions")
struct SmartPlaylistSortConventionTests {
    private func source(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("Detail view renders a sortable table and preserves the SQL order")
    func detailViewSortsAndPreservesOrder() throws {
        let source = try self.source("Sources/UI/Playlists/Smart/SmartPlaylistDetailView.swift")
        #expect(source.contains("sortable: true"), "smart playlist track list must have clickable headers")
        #expect(
            source.contains("preserveOrder: true"),
            "loaded tracks must preserve the SQL order or the smart playlist's Sort By is discarded"
        )
        #expect(
            source.contains("setSort(columns:"),
            "the table sort must be seeded from the playlist's sort descriptors"
        )
    }

    @Test("Editor exposes a reorderable multi-key sort list")
    func editorOffersMultiKeySort() throws {
        let source = try self.source("Sources/UI/Playlists/Smart/LimitAndSortView.swift")
        #expect(source.contains("sortDescriptors"), "the editor must bind to the multi-key sortDescriptors list")
        #expect(source.contains("L10n.string(\"Add sort key\")"), "the editor must let the user add sort keys")
        #expect(source.contains("L10n.string(\"then by\")"), "secondary sort rows must read \"then by\"")
    }
}
