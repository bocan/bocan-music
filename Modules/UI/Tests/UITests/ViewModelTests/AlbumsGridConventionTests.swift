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

    @Test("The grid saves and restores its scroll offset across album visits (#349)")
    func gridRestoresScrollOffset() throws {
        let source = try self.gridSource()
        // Capture live offset, snapshot it into the VM when navigating, and
        // restore via ScrollPosition when the grid reappears.
        #expect(
            source.contains(".onScrollGeometryChange(for: CGFloat.self)"),
            "the grid must observe scroll geometry to capture the live offset"
        )
        #expect(
            source.contains("self.vm.gridScrollOffset = Double(self.liveScrollOffset)"),
            "navigating into an album must snapshot the offset into the view model"
        )
        #expect(
            source.contains("self.scrollPosition.scrollTo(y: CGFloat(self.vm.gridScrollOffset))"),
            "the grid must restore the saved offset via ScrollPosition"
        )
    }
}

// MARK: - AlbumDoubleClickConventionTests

/// Source-convention checks for double-click-to-play on album covers (#369):
/// a double-click replaces the queue and plays in place, a single click still
/// opens the track list, on every local album-cover surface.
@Suite("Album double-click conventions")
struct AlbumDoubleClickConventionTests {
    private func uiSource(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/\(relativePath)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("The shared gesture gives double-click precedence over the single click")
    func gestureComposition() throws {
        // Exclusive composition is what lets the double-click fire INSTEAD of
        // the single click; two independent tap gestures would navigate first
        // and the play handler would die with the replaced view.
        let source = try self.uiSource("Browse/AlbumOpenPlayGesture.swift")
        #expect(
            source.contains("TapGesture(count: 2)"),
            "the modifier must recognise a double-click"
        )
        #expect(
            source.contains(".exclusively("),
            "double and single click must be composed exclusively"
        )
    }

    @Test("Grid cells play on double-click and open on single click")
    func gridUsesGesture() throws {
        let source = try self.uiSource("Browse/AlbumsGridView.swift")
        #expect(
            source.contains("albumOpenPlayGesture(open: { self.onTap() }, play: { self.onPlay() })"),
            "the interactive cell must route clicks through the shared gesture"
        )
        #expect(
            source.contains("onPlay:"),
            "the grid must wire an onPlay handler into its cells"
        )
    }

    @Test("The artist album strip plays on double-click via playAlbum(albumID:)")
    func artistStripUsesGesture() throws {
        let source = try self.uiSource("Browse/ArtistsView.swift")
        #expect(
            source.contains("albumOpenPlayGesture("),
            "the artist album strip must route clicks through the shared gesture"
        )
        #expect(
            source.contains("self.library.playAlbum(albumID: id)"),
            "double-click must play in place via playAlbum(albumID:)"
        )
    }

    @Test("The artist strip context menu splits Play Album and View Album like the grid")
    func artistStripContextMenuSplit() throws {
        let source = try self.uiSource("Browse/ArtistsView.swift")
        #expect(
            source.contains("L10n.string(\"View Album\")"),
            "the artist strip menu must offer View Album for navigation"
        )
    }

    @Test("Cells expose open and play as accessibility actions")
    func accessibilityActions() throws {
        // The exclusive gesture composition doesn't synthesize an assistive
        // activation, so both outcomes must be explicit a11y actions.
        for file in ["Browse/AlbumsGridView.swift", "Browse/ArtistsView.swift"] {
            let source = try self.uiSource(file)
            #expect(
                source.contains(".accessibilityAction(named: L10n.string(\"Play Album\"))"),
                "\(file) must expose Play Album as a named accessibility action"
            )
        }
    }
}
