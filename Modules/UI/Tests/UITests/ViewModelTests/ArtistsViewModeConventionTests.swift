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
            source.contains("@CollectionViewModeStorage(\"artists.viewMode\")"),
            "the Artists view mode must persist via @CollectionViewModeStorage(\"artists.viewMode\")"
        )
    }

    @Test("The view-mode storage is String-backed and defaults to .list")
    func stringBackedStorage() throws {
        // The wrapper stores the raw String, not the enum, so a write from the
        // "View as" menu reliably redraws this separate instance. A refactor back
        // to a RawRepresentable @AppStorage reintroduces the cross-instance
        // stale-view bug (phase 23-3); this pins the fix.
        let source = try self.browseSource("CollectionViewMode.swift")
        #expect(
            source.contains("@AppStorage private var rawValue: String"),
            "CollectionViewModeStorage must persist a primitive String for reliable cross-instance updates"
        )
        #expect(
            source.contains("CollectionViewMode.list.rawValue"),
            "the storage wrapper must default to .list so list mode is unchanged by default"
        )
    }

    @Test("ArtistsView presents the shared List/Grid toggle")
    func segmentedPicker() throws {
        let source = try self.browseSource("ArtistsView.swift")
        #expect(
            source.contains("CollectionViewModeToggle(mode: self.$viewMode)"),
            "the List/Grid toggle must be the shared CollectionViewModeToggle component"
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
