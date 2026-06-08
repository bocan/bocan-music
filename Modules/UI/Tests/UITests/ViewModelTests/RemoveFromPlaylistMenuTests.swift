import Foundation
import Testing

// MARK: - RemoveFromPlaylistMenuTests

/// "Remove from Playlist" must sit directly under "Add to Playlist" in the track
/// context menu, not buried among "Remove from Library" / "Delete from Disk" at
/// the bottom (where it read as just another destructive removal and was easy to
/// miss). It must also advertise the ⌫ Delete shortcut so the keyboard
/// affordance is discoverable. The actual keypress is handled by
/// `ContextMenuTableView`; the menu key equivalent is for display.
@Suite("Remove from Playlist menu placement")
struct RemoveFromPlaylistMenuTests {
    private func coordinatorSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ViewModelTests/
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/Browse/TrackTableCoordinator.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Returns the body of the named `private func` up to the next `private func`.
    private func methodBody(named name: String, in source: String) -> String? {
        guard let start = source.range(of: "private func \(name)(") else { return nil }
        let rest = source[start.upperBound...]
        let end = rest.range(of: "private func ")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    @Test("Remove from Playlist is grouped under Add to Playlist with a Delete shortcut")
    func removeIsGroupedUnderAddToPlaylist() throws {
        let source = try self.coordinatorSource()
        let playbackBody = try #require(
            self.methodBody(named: "addPlaybackItems", in: source),
            "addPlaybackItems must exist"
        )

        let addRange = try #require(
            playbackBody.range(of: "\"Add to Playlist\""),
            "addPlaybackItems must offer Add to Playlist"
        )
        let removeRange = try #require(
            playbackBody.range(of: "\"Remove from Playlist\""),
            "Remove from Playlist must live in addPlaybackItems, next to Add to Playlist"
        )
        #expect(
            addRange.lowerBound < removeRange.lowerBound,
            "Remove from Playlist must come directly after Add to Playlist"
        )
        #expect(
            playbackBody.contains("rp.keyEquivalent = \"\\u{8}\""),
            "Remove from Playlist must advertise the Delete (⌫) key equivalent"
        )
    }

    @Test("Remove from Playlist is no longer mixed in with the library/disk removals")
    func removeNotInFileItems() throws {
        let source = try self.coordinatorSource()
        let fileBody = try #require(
            self.methodBody(named: "addFileItems", in: source),
            "addFileItems must exist"
        )
        #expect(
            !fileBody.contains("\"Remove from Playlist\""),
            "Remove from Playlist must not sit alongside Remove from Library / Delete from Disk"
        )
        // The destructive library/disk removals stay grouped together here.
        #expect(fileBody.contains("\"Remove from Library\""))
        #expect(fileBody.contains("\"Delete from Disk\""))
    }
}
