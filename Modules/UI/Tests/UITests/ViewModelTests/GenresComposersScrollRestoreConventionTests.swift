import Foundation
import Testing

// MARK: - GenresComposersScrollRestoreConventionTests

/// Source-convention checks for `GenresView` / `ComposersView` scroll-restore
/// behaviour that can't be exercised host-less: returning from a genre or
/// composer re-centers the one you visited instead of snapping back to the top
/// of the list (mirrors the artist-list scroll restore, #349).
@Suite("Genres/Composers scroll restore conventions")
struct GenresComposersScrollRestoreConventionTests {
    private func source(_ fileName: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/Browse/\(fileName)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("The genre list snapshots the visited genre and re-centers it on return (#349)")
    func genreListRestoresScrollPosition() throws {
        let source = try self.source("GenresView.swift")
        #expect(
            source.contains("self.library.lastVisitedGenre = genre"),
            "navigating into a genre must snapshot it into the library view model"
        )
        #expect(
            source.contains("proxy.scrollTo(genre, anchor: .center)"),
            "the genre list must re-center the last-visited genre via ScrollViewProxy"
        )
    }

    @Test("The composer list snapshots the visited composer and re-centers it on return (#349)")
    func composerListRestoresScrollPosition() throws {
        let source = try self.source("ComposersView.swift")
        #expect(
            source.contains("self.library.lastVisitedComposer = composer"),
            "navigating into a composer must snapshot it into the library view model"
        )
        #expect(
            source.contains("proxy.scrollTo(composer, anchor: .center)"),
            "the composer list must re-center the last-visited composer via ScrollViewProxy"
        )
    }
}
