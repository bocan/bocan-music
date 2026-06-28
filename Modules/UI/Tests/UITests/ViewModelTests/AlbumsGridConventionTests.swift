import Foundation
import Testing

// MARK: - AlbumsGridConventionTests

/// Source-convention checks for `AlbumsGridView` behaviour that can't be
/// exercised host-less: the Play Album / View Album context-menu split (#349).
@Suite("AlbumsGrid conventions")
struct AlbumsGridConventionTests {
    private func gridSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/Browse/AlbumsGridView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("Single-album context menu offers Play Album (in place) and View Album (navigate)")
    func contextMenuSplitsPlayAndView() throws {
        let source = try self.gridSource()
        #expect(source.contains("L10n.string(\"Play Album\")"), "menu must offer Play Album")
        #expect(source.contains("L10n.string(\"View Album\")"), "menu must offer View Album")
        // Play Album plays in place (no navigation); View Album navigates.
        #expect(
            source.contains("self.library.playAlbum(albumID:"),
            "Play Album must call playAlbum(albumID:) to play in place"
        )
        #expect(
            source.contains("self.vm.selectedAlbumID = album.id"),
            "View Album must navigate by setting selectedAlbumID"
        )
    }

    @Test("Multi-select Play N Albums plays in place rather than navigating per album")
    func multiPlayPlaysInPlace() throws {
        let source = try self.gridSource()
        #expect(
            source.contains("self.library.playAlbums(albumIDs:"),
            "multi-select must play via playAlbums(albumIDs:)"
        )
    }
}
