import Foundation
import Testing

// MARK: - GenresComposersSortConventionTests

/// Source-convention checks for the Genres / Composers sort choosers, whose
/// sorting lives in `View` private helpers that can't be exercised host-less.
@Suite("Genres/Composers sort conventions")
struct GenresComposersSortConventionTests {
    /// Concatenates the named Browse source files. The sort work is split across
    /// each view file (the `@AppStorage` and `SortMenu`) and the shared
    /// `GenresComposersSort.swift` (the enums), so tests read both.
    private func source(_ fileNames: String...) throws -> String {
        let base = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/Browse")
        return try fileNames
            .map { try String(contentsOf: base.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")
    }

    @Test("Genres default to song count and offer a genre-name option via a SortMenu")
    func genresSortChooser() throws {
        let source = try self.source("GenresView.swift", "GenresComposersSort.swift")
        #expect(
            source.contains("@AppStorage(\"genres.sortOrder\") private var sortOrder: GenreSortOrder = .songCount"),
            "genres must default to song count and persist via @AppStorage"
        )
        #expect(source.contains("enum GenreSortOrder"), "a GenreSortOrder enum must exist")
        #expect(
            source.contains("L10n.string(\"Genre Name\")") && source.contains("L10n.string(\"Song Count\")"),
            "the genre sort menu must offer Genre Name and Song Count"
        )
        #expect(source.contains("SortMenu(selection: self.$sortOrder"), "genres must present a SortMenu")
    }

    @Test("Composers default to composer name and offer a song-count option via a SortMenu")
    func composersSortChooser() throws {
        let source = try self.source("ComposersView.swift", "GenresComposersSort.swift")
        #expect(
            source.contains(
                "@AppStorage(\"composers.sortOrder\") private var sortOrder: ComposerSortOrder = .composerName"
            ),
            "composers must default to composer name and persist via @AppStorage"
        )
        #expect(source.contains("enum ComposerSortOrder"), "a ComposerSortOrder enum must exist")
        #expect(
            source.contains("L10n.string(\"Composer Name\")"),
            "the composer sort menu must offer Composer Name"
        )
    }
}
