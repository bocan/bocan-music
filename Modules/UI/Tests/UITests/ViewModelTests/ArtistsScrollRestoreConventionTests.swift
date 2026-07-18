import Foundation
import Testing

// MARK: - ArtistsScrollRestoreConventionTests

/// Source-convention checks for `ArtistsView` scroll-restore behaviour that
/// can't be exercised host-less: returning from an artist re-centers the
/// last-visited artist instead of snapping back to the top of the list
/// (mirrors the album-grid scroll restore, #349).
@Suite("Artists scroll restore conventions")
struct ArtistsScrollRestoreConventionTests {
    private func artistsSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/Browse/ArtistsView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("Artist rows provide selection tags so clicks can navigate")
    func artistRowsProvideSelectionTags() throws {
        let source = try self.artistsSource()
        #expect(
            source.contains(".tag(artist.id)"),
            "List(selection:) only updates selectedArtistID when each artist row has a matching tag"
        )
    }

    @Test("The list snapshots the visited artist and re-centers it on return (#349)")
    func listRestoresScrollPosition() throws {
        let source = try self.artistsSource()
        // The list lives inside a ScrollViewReader so it can scroll to a row by id.
        #expect(
            source.contains("ScrollViewReader { proxy in"),
            "the artist list must be wrapped in a ScrollViewReader to scroll to a row"
        )
        // Navigating into an artist snapshots its id into the view model.
        #expect(
            source.contains("self.vm.lastVisitedArtistID = id"),
            "navigating into an artist must snapshot the id into the view model"
        )
        // On return the saved artist is scrolled back to the centre of the list.
        #expect(
            source.contains("proxy.scrollTo(self.vm.lastVisitedArtistID, anchor: .center)"),
            "the list must re-center the last-visited artist via ScrollViewProxy"
        )
    }

    @Test("The artist's album strip saves and restores its scroll offset across album visits (#349)")
    func albumStripRestoresScrollOffset() throws {
        let source = try self.artistsSource()
        // Capture the live offset of the album strip.
        #expect(
            source.contains(".onScrollGeometryChange(for: CGFloat.self)"),
            "the album strip must observe scroll geometry to capture the live offset"
        )
        // Opening an album snapshots the offset into the library view model, keyed by artist.
        #expect(
            source.contains("self.library.artistAlbumScrollOffsets[self.artistID] = Double(self.liveAlbumScrollOffset)"),
            "opening an album must snapshot the strip offset into the library view model"
        )
        // On return the strip restores the saved offset via ScrollPosition.
        #expect(
            source.contains("self.albumScrollPosition.scrollTo(y: CGFloat(offset))"),
            "the album strip must restore the saved offset via ScrollPosition"
        )
    }
}
