import Foundation
import Metadata
import Testing
@testable import Library

@Suite("TagDiff")
struct TagDiffTests {
    // MARK: - diff

    @Test func diffEmpty_whenTagsIdentical() {
        let tags = TrackTags(title: "Same", artist: "Same Artist")
        let patch = TagDiff.diff(before: tags, after: tags)
        #expect(patch.isEmpty)
    }

    @Test func diffTitle() {
        let before = TrackTags(title: "Old")
        let after = TrackTags(title: "New")
        let patch = TagDiff.diff(before: before, after: after)
        #expect(patch.title == .some("New"))
        #expect(patch.artist == nil)
    }

    @Test func diffClearField() {
        let before = TrackTags(genre: "Rock")
        let after = TrackTags(genre: nil)
        let patch = TagDiff.diff(before: before, after: after)
        // genre changed: .some(nil) = clear
        #expect(patch.genre == .some(nil))
    }

    @Test func diffMultipleFields() {
        let before = TrackTags(title: "Old", artist: "Old Artist", year: 2000)
        let after = TrackTags(title: "New", artist: "Old Artist", year: 2024)
        let patch = TagDiff.diff(before: before, after: after)
        #expect(patch.title == .some("New"))
        #expect(patch.artist == nil) // unchanged
        #expect(patch.year == .some(2024))
    }

    @Test func diffReplayGain() {
        let rg1 = ReplayGain(trackGain: -3.0)
        let rg2 = ReplayGain(trackGain: -5.0)
        let before = TrackTags(replayGain: rg1)
        let after = TrackTags(replayGain: rg2)
        let patch = TagDiff.diff(before: before, after: after)
        #expect(patch.replaygainTrackGain == .some(-5.0))
        #expect(patch.replaygainTrackPeak == nil)
    }

    // MARK: - merge

    @Test func mergeLaterWins() {
        var p1 = TrackTagPatch()
        p1.title = "First"
        var p2 = TrackTagPatch()
        p2.title = "Second"
        let merged = TagDiff.merge([p1, p2])
        #expect(merged.title == .some("Second"))
    }

    @Test func mergeUnionOfFields() {
        var p1 = TrackTagPatch()
        p1.title = "Title"
        var p2 = TrackTagPatch()
        p2.artist = "Artist"
        let merged = TagDiff.merge([p1, p2])
        #expect(merged.title == .some("Title"))
        #expect(merged.artist == .some("Artist"))
    }

    @Test func mergeEmpty() {
        let merged = TagDiff.merge([])
        #expect(merged.isEmpty)
    }
}
