import Foundation
import Testing
@testable import UI

// MARK: - AlbumDetailShowOriginalConventionTests

/// #583: "Show Original Cover" opens the full-size image that `CoverArtFiles`
/// resolves (the kept original of a cover over 4096 px, else the working
/// file). It is offered on the album page's artwork and on an Albums grid
/// tile, through one shared opener. The views are SwiftUI, so this pins the
/// source contract; `CoverArtFilesTests` covers the resolution.
@Suite("Show Original Cover")
struct AlbumDetailShowOriginalConventionTests {
    private func source(_ relativePath: String) throws -> String {
        // #filePath: .../Modules/UI/Tests/UITests/AlbumDetailShowOriginalConventionTests.swift
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/Browse")
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("The opener opens the full-size cover and tells the user when it cannot")
    func openerOpensFullSize() throws {
        let code = try self.source("OriginalCoverOpener.swift")
        #expect(code.contains("CoverArtFiles.fullSizeURL(forWorkingPath: workingPath)"))
        #expect(code.contains("NSWorkspace.shared.open(url)"))
        #expect(code.contains("L10n.string(\"The cover image is no longer on disk.\")"))
        #expect(code.contains("L10n.string(\"Couldn’t open the cover image.\")"))
    }

    @Test("The album page and the Albums grid both offer it through the opener", arguments: [
        "AlbumDetailView.swift", "AlbumsGridView.swift",
    ])
    func surfacesUseTheOpener(file: String) throws {
        let code = try self.source(file)
        #expect(code.contains("Button(L10n.string(\"Show Original Cover\"))"), "\(file) lacks the menu item")
        #expect(code.contains("OriginalCoverOpener.open(workingPath: path"), "\(file) does not use the opener")
    }

    @Test("Switching albums clears the previous cover before loading")
    func loadClearsPreviousCover() throws {
        let code = try self.source("AlbumDetailView.swift")
        let load = try #require(code.range(of: "private func load() async {"))
        let body = code[load.upperBound...]
        let firstTracksLoad = try #require(body.range(of: "await self.library.tracks.load"))
        let prefix = body[..<firstTracksLoad.lowerBound]
        #expect(prefix.contains("self.artwork = nil"))
        #expect(prefix.contains("self.coverPath = nil"))
    }
}
