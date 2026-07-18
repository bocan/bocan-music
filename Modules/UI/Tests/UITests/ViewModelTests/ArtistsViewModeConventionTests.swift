import Foundation
import Testing

// MARK: - ArtistsViewModeConventionTests

/// Source-convention checks for the Artists List / Grid toggle (phase 23-1).
/// These facts (an `@AppStorage` key, a segmented `Picker`, the grid open path)
/// can't be exercised host-less, so they're asserted against the source text,
/// following the established `#filePath` convention.
@Suite("Artists view-mode conventions")
struct ArtistsViewModeConventionTests {
    private func browseSource(_ fileName: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/Browse/\(fileName)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("ArtistsView persists the view mode under artists.viewMode")
    func persistsViewMode() throws {
        let source = try self.browseSource("ArtistsView.swift")
        #expect(
            source.contains("@AppStorage(\"artists.viewMode\")"),
            "the Artists view mode must persist via @AppStorage(\"artists.viewMode\")"
        )
        #expect(
            source.contains("CollectionViewMode = .list"),
            "the persisted default must be .list so list mode is unchanged by default"
        )
    }

    @Test("ArtistsView presents a segmented view-mode picker")
    func segmentedPicker() throws {
        let source = try self.browseSource("ArtistsView.swift")
        #expect(
            source.contains(".pickerStyle(.segmented)"),
            "the List/Grid toggle must be a segmented Picker"
        )
        #expect(
            source.contains("square.grid.2x2") && source.contains("list.bullet"),
            "the toggle must use the list.bullet and square.grid.2x2 icons"
        )
    }

    @Test("Grid mode is only shown when the stored mode is .grid")
    func gridBranch() throws {
        let source = try self.browseSource("ArtistsView.swift")
        #expect(
            source.contains("self.viewMode == .grid"),
            "grid content must be gated on the persisted view mode"
        )
        #expect(
            source.contains("ArtistsGridContent(vm: self.vm, library: self.library)"),
            "grid mode must render ArtistsGridContent"
        )
    }

    @Test("The grid open path snapshots lastVisitedArtistID and navigates to the artist")
    func gridOpenPath() throws {
        let source = try self.browseSource("ArtistsGridContent.swift")
        #expect(
            source.contains("self.vm.lastVisitedArtistID = id"),
            "opening a card must snapshot the id for scroll restore, matching the list row"
        )
        #expect(
            source.contains("self.library.selectDestination(.artist(id))"),
            "opening a card must navigate to the artist destination"
        )
    }
}
