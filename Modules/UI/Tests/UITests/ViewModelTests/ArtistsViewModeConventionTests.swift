import Foundation
import Testing

// MARK: - ArtistsViewModeConventionTests

/// Source-convention checks for the Artists List / Grid toggle (ADR-072).
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
        // stale-view bug (ADR-074); this pins the fix.
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

// MARK: - ArtistScopeConventionTests

/// Source-convention checks for the Artists scope filter (#369). The funnel
/// icon's filled state is the only always-visible sign that a persisted filter
/// is hiding artists, so these pin the menu, the icon swap, and the persistence
/// key against silent regression.
@Suite("Artists scope filter conventions")
struct ArtistScopeConventionTests {
    private func uiSource(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/\(relativePath)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("ArtistsView presents the scope filter menu")
    func presentsScopeMenu() throws {
        let source = try self.uiSource("Browse/ArtistsView.swift")
        #expect(
            source.contains("ArtistScopeMenu(selection: self.scopeBinding)"),
            "the Artists toolbar must present the shared ArtistScopeMenu"
        )
    }

    @Test("The funnel icon fills when the albumArtists scope is active")
    func funnelFillsWhenFiltered() throws {
        // The filled funnel is the platform's "a filter is active" signal and
        // the only indication visible with the menu closed; losing the swap
        // silently hides artists with no on-screen explanation.
        let source = try self.uiSource("Browse/ArtistScopeMenu.swift")
        #expect(
            source.contains("self.selection == .albumArtists"),
            "the icon must be gated on the albumArtists scope"
        )
        #expect(
            source.contains("\"line.3.horizontal.decrease.circle.fill\""),
            "the active state must use the filled funnel"
        )
        #expect(
            source.contains("\"line.3.horizontal.decrease.circle\""),
            "the inactive state must use the outline funnel"
        )
    }

    @Test("The scope is persisted under artists.scope")
    func persistsScope() throws {
        let source = try self.uiSource("ViewModels/ArtistsViewModel.swift")
        #expect(
            source.contains("scopeKey = \"artists.scope\""),
            "the scope must persist under the artists.scope UserDefaults key"
        )
    }

    @Test("The filtered empty state offers a one-click return to All Artists")
    func emptyStateEscapeHatch() throws {
        let source = try self.uiSource("Browse/ArtistsView.swift")
        #expect(
            source.contains("self.vm.setScope(.allArtists)"),
            "the No Album Artists empty state must reset the scope in one click"
        )
    }
}
