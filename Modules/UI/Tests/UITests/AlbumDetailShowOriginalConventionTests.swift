import Foundation
import Testing
@testable import UI

// MARK: - AlbumDetailShowOriginalConventionTests

/// #583: the album page's artwork offers "Show Original Cover", which opens
/// the full-size image that `CoverArtFiles` resolves (the kept original of a
/// cover over 4096 px, else the working file). The view is SwiftUI, so this
/// pins the source contract; `CoverArtFilesTests` covers the resolution.
@Suite("Album page Show Original Cover")
struct AlbumDetailShowOriginalConventionTests {
    private func source() throws -> String {
        // #filePath: .../Modules/UI/Tests/UITests/AlbumDetailShowOriginalConventionTests.swift
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/Browse/AlbumDetailView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("The artwork's context menu opens the full-size cover")
    func contextMenuOpensFullSize() throws {
        let code = try self.source()
        #expect(code.contains(".contextMenu {"))
        #expect(code.contains("Button(L10n.string(\"Show Original Cover\")) { self.showOriginalCover() }"))
        #expect(code.contains("CoverArtFiles.fullSizeURL(forWorkingPath: path)"))
        #expect(code.contains("NSWorkspace.shared.open(url)"))
    }

    @Test("A failed open tells the user")
    func failuresReachTheUser() throws {
        let code = try self.source()
        #expect(code.contains("L10n.string(\"The cover image is no longer on disk.\")"))
        #expect(code.contains("L10n.string(\"Couldn’t open the cover image.\")"))
    }

    @Test("Switching albums clears the previous cover before loading")
    func loadClearsPreviousCover() throws {
        let code = try self.source()
        let load = try #require(code.range(of: "private func load() async {"))
        let body = code[load.upperBound...]
        let firstTracksLoad = try #require(body.range(of: "await self.library.tracks.load"))
        let prefix = body[..<firstTracksLoad.lowerBound]
        #expect(prefix.contains("self.artwork = nil"))
        #expect(prefix.contains("self.coverPath = nil"))
    }
}
