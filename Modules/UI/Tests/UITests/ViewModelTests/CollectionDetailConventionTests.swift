import Foundation
import Testing

// MARK: - CollectionDetailConventionTests

/// Source-convention checks for the genre/composer destination Songs / Albums
/// switch (phase 23-3). These wire-ups can't be exercised host-less.
@Suite("Collection detail (Songs/Albums) conventions")
struct CollectionDetailConventionTests {
    private func uiSource(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/\(relativePath)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("ContentPane reads the per-section detail modes and routes to CollectionDetailView")
    func contentPaneWiring() throws {
        let source = try self.uiSource("AppRoot/ContentPane.swift")
        #expect(source.contains("@AppStorage(\"genres.detailMode\")"))
        #expect(source.contains("@AppStorage(\"composers.detailMode\")"))
        #expect(source.contains("CollectionDetailView(name: genre, kind: .genre"))
        #expect(source.contains("CollectionDetailView(name: c, kind: .composer"))
    }

    @Test("The destination presents a segmented Songs / Albums picker")
    func detailModePicker() throws {
        let source = try self.uiSource("Browse/CollectionDetailView.swift")
        #expect(source.contains(".pickerStyle(.segmented)"))
        #expect(source.contains("music.note.list") && source.contains("square.grid.2x2"))
        #expect(source.contains("CollectionDetailMode.songs") && source.contains("CollectionDetailMode.albums"))
    }

    @Test("Albums mode loads a locally-owned view model filtered by the collection")
    func albumsModeFilteredLoad() throws {
        let source = try self.uiSource("Browse/CollectionDetailView.swift")
        // Locally-owned VM so a filtered load never corrupts the shared Albums grid.
        #expect(source.contains("@StateObject private var albumsVM"))
        #expect(source.contains("self.albumsVM.load(genre: self.name)"))
        #expect(source.contains("self.albumsVM.load(composer: self.name)"))
        // Songs mode stays on the shared tracks VM (unchanged behaviour).
        #expect(source.contains("TracksView(vm: self.library.tracks, library: self.library, title: self.name)"))
    }
}
