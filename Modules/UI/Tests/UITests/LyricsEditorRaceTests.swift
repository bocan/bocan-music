import Foundation
import Testing
@testable import UI

// MARK: - LyricsEditorRaceTests

/// Source-convention checks for the fix to the lyrics editor showing stale-empty
/// text when opened for a track that was not yet being observed. The live view
/// tree and the async resolution cannot be exercised host-less, so these assert
/// the structural wiring that closes the race: the editor re-syncs when the
/// document resolves, the guard protects in-progress edits, and the view model
/// resolves stored lyrics before presenting the sheet.
@Suite("Lyrics editor race source conventions")
struct LyricsEditorRaceTests {
    private func source(_ relativePath: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func sheetSource() throws -> String {
        try self.source("Sources/UI/Lyrics/LyricsEditorSheet.swift")
    }

    private func viewModelSource() throws -> String {
        try self.source("Sources/UI/Lyrics/LyricsViewModel.swift")
    }

    @Test("Editor re-applies the document when it resolves after the sheet appears")
    func editorReactsToLateDocument() throws {
        let source = try self.sheetSource()
        #expect(source.contains(".onChange(of: self.vm.document)"))
        #expect(source.contains("applyDocumentText"))
    }

    @Test("Late document does not clobber in-progress edits")
    func editorGuardsUserEdits() throws {
        let source = try self.sheetSource()
        #expect(source.contains("guard self.text == self.lastLoaded else { return }"))
    }

    @Test("openEditor(for:) resolves stored lyrics before presenting the sheet")
    func openEditorResolvesBeforePresenting() throws {
        let source = try self.viewModelSource()
        #expect(source.contains("service.lyricsWithSource(for: trackID)"))
    }

    @Test("A force fetch for the current track is surfaced immediately")
    func forceFetchReflectsCurrentTrack() throws {
        let source = try self.viewModelSource()
        #expect(source.contains("reflectFetched"))
        #expect(source.contains("guard let doc, self.currentTrackID == trackID else { return }"))
    }
}
