import Foundation
import Testing

// MARK: - GenresComposersViewModeConventionTests

/// Source-convention checks for the Genres / Composers List / Grid toggles
/// (phase 23-2), mirroring the Artists checks. These facts can't be exercised
/// host-less, so they're asserted against the source text.
@Suite("Genres/Composers view-mode conventions")
struct GenresComposersViewModeConventionTests {
    private func browseSource(_ fileName: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/Browse/\(fileName)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("Genres persist the view mode, default to list, and present a segmented picker")
    func genresToggle() throws {
        let source = try self.browseSource("GenresView.swift")
        #expect(source.contains("@AppStorage(\"genres.viewMode\")"))
        #expect(source.contains("CollectionViewMode = .list"))
        #expect(source.contains(".pickerStyle(.segmented)"))
        #expect(source.contains("square.grid.2x2") && source.contains("list.bullet"))
    }

    @Test("Genres grid opens the genre and snapshots it for scroll restore")
    func genresGridOpen() throws {
        let source = try self.browseSource("GenresView.swift")
        #expect(source.contains("self.viewMode == .grid"))
        #expect(source.contains("self.library.lastVisitedGenre = name"))
        #expect(source.contains("self.library.selectDestination(.genre(name))"))
    }

    @Test("Composers persist the view mode, default to list, and present a segmented picker")
    func composersToggle() throws {
        let source = try self.browseSource("ComposersView.swift")
        #expect(source.contains("@AppStorage(\"composers.viewMode\")"))
        #expect(source.contains("CollectionViewMode = .list"))
        #expect(source.contains(".pickerStyle(.segmented)"))
        #expect(source.contains("square.grid.2x2") && source.contains("list.bullet"))
    }

    @Test("Composers grid opens the composer and snapshots it for scroll restore")
    func composersGridOpen() throws {
        let source = try self.browseSource("ComposersView.swift")
        #expect(source.contains("self.viewMode == .grid"))
        #expect(source.contains("self.library.lastVisitedComposer = name"))
        #expect(source.contains("self.library.selectDestination(.composer(name))"))
    }
}
