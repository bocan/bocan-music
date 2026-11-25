import Foundation
import Library
import Testing
@testable import UI

// MARK: - PlaylistAddNoticeTests

/// An add to a playlist that skips songs it already holds says so (#720).
/// The message itself is a pure function; the wiring at each add path is a
/// view and view-model detail that host-less tests cannot drive, so it is
/// pinned by source convention.
@Suite("Playlist add notice (#720)")
struct PlaylistAddNoticeTests {
    @Test("no message when nothing was skipped")
    func nothingSkipped() {
        #expect(PlaylistAddNotice.message(for: PlaylistAddResult(added: 3, skipped: 0)) == nil)
        #expect(PlaylistAddNotice.message(for: PlaylistAddResult(added: 0, skipped: 0)) == nil)
    }

    @Test("a message when songs were skipped, added or not")
    func skipped() {
        let allSkipped = PlaylistAddNotice.message(for: PlaylistAddResult(added: 0, skipped: 1))
        let someSkipped = PlaylistAddNotice.message(for: PlaylistAddResult(added: 2, skipped: 3))
        #expect(allSkipped?.kind == .info)
        #expect(someSkipped?.kind == .info)
        #expect(allSkipped?.text.isEmpty == false)
    }

    private func source(_ relativePath: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("every add path turns the add result into the message", arguments: [
        "Sources/UI/Browse/TracksView+Actions.swift",
        "Sources/UI/Playlists/PlaylistDetailView.swift",
        "Sources/UI/Playlists/ViewModels/PlaylistSidebarViewModel.swift",
    ])
    func addPathsShowNotice(_ path: String) throws {
        #expect(try self.source(path).contains("PlaylistAddNotice.message(for: result)"))
    }

    @Test("the sidebar's notices reach the app toast")
    func sidebarNoticeWired() throws {
        let source = try self.source("Sources/UI/ViewModels/LibraryViewModel.swift")
        #expect(source.contains("self.playlistSidebar.onNotice = {"))
    }

    @Test("the open playlist's drops go through the notice helper, not the view model directly")
    func detailDropsUseHelper() throws {
        let source = try self.source("Sources/UI/Playlists/PlaylistDetailView.swift")
        #expect(!source.contains("await self.vm.addTracks(ids)"))
        #expect(!source.contains("await vm.addTracks(ids, at: index)"))
    }
}
