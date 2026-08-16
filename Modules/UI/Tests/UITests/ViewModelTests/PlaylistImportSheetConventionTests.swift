import Foundation
import Testing
@testable import UI

// MARK: - PlaylistImportSheetConventionTests

/// Source-convention guards for the import sheet's CUE access flow (#391).
/// The panel choreography cannot run host-less, so pin the structure: after
/// picking files, the sheet probes each cue's referenced audio for sandbox
/// readability and, when blocked, asks for a folder grant so the import's
/// bookmark minting can succeed.
@Suite("PlaylistImportSheet conventions")
struct PlaylistImportSheetConventionTests {
    private func sheetSource() throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/PlaylistIO/PlaylistImportSheet.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("picking files triggers the CUE audio access probe before previewing")
    func accessProbeWired() throws {
        let source = try self.sheetSource()
        let pick = try #require(source.range(of: "self.pickedURLs = panel.urls"))
        let probe = try #require(source.range(of: "await self.requestCueAudioAccessIfNeeded()"))
        let preview = try #require(source.range(of: "await self.refreshPreview()"))
        #expect(pick.lowerBound < probe.lowerBound && probe.lowerBound < preview.lowerBound)
    }

    @Test("the grant panel asks for a folder, seeded at the cue's own directory")
    func grantPanelShape() throws {
        let source = try self.sheetSource()
        // The root-aware probe, not the raw readability check: audio under a
        // library root must never trigger the prompt (the common case stays
        // silent; the panel is strictly a last resort).
        #expect(source.contains("await self.importer.cueAudioNeedingAccess(at: url)"))
        #expect(!source.contains("CUESheetReader.inaccessibleAudio"))
        #expect(source.contains("panel.canChooseDirectories = true"))
        #expect(source.contains("panel.directoryURL = firstCue.deletingLastPathComponent()"))
    }
}
