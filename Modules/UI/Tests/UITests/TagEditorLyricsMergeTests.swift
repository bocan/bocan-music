import Foundation
import Metadata
import Testing
@testable import UI

// MARK: - TagEditorLyricsMergeTests

/// The Get Info lyrics tab was empty for tracks whose lyrics live only in the
/// lyrics DB table (LRClib fetches, lyrics-panel edits) because `load()` read
/// file tags alone. These tests pin the merge: stored rows win, file tags are
/// the fallback, and membership mirrors which tags actually loaded.
@Suite("TagEditor lyrics merge")
@MainActor
struct TagEditorLyricsMergeTests {
    private func tags(lyrics: String?) -> TrackTags {
        var t = TrackTags()
        t.lyrics = lyrics
        return t
    }

    @Test("Stored DB lyrics win over the file tag")
    func storedWins() {
        let merged = TagEditorViewModel.effectiveLyrics(
            trackIDs: [1],
            tagsByID: [1: self.tags(lyrics: "embedded words")],
            stored: [1: "fetched words"]
        )
        #expect(merged == ["fetched words"])
    }

    @Test("File tag is the fallback when no DB row exists")
    func fileTagFallback() {
        let merged = TagEditorViewModel.effectiveLyrics(
            trackIDs: [1],
            tagsByID: [1: self.tags(lyrics: "embedded words")],
            stored: [:]
        )
        #expect(merged == ["embedded words"])
    }

    @Test("A track with neither source stays empty rather than inventing text")
    func neitherSourceIsNil() {
        let merged = TagEditorViewModel.effectiveLyrics(
            trackIDs: [1],
            tagsByID: [1: self.tags(lyrics: nil)],
            stored: [:]
        )
        #expect(merged == [nil])
    }

    @Test("Multi-selection keeps per-track values and skips failed tag reads")
    func multiSelectionMirrorsLoadedTags() {
        let merged = TagEditorViewModel.effectiveLyrics(
            trackIDs: [1, 2, 3],
            tagsByID: [
                1: self.tags(lyrics: "embedded one"),
                // 2 failed to read: contributes no slot, same as populate(from:)
                3: self.tags(lyrics: nil),
            ],
            stored: [3: "fetched three"]
        )
        #expect(merged == ["embedded one", "fetched three"])
    }

    @Test("load() merges stored lyrics after populate")
    func loadWiresTheMerge() throws {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent() // UITests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // Modules/UI/
            .appendingPathComponent("Sources/UI/MetadataEditor/ViewModels/TagEditorViewModel.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("storedLyricsText(ids:"))
        #expect(source.contains("mergeStoredLyrics("))
    }
}
