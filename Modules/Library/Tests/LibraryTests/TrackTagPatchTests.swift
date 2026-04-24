import Foundation
import Persistence
import Testing
@testable import Library

@Suite("TrackTagPatch")
struct TrackTagPatchTests {
    private func makeTrack() -> Track {
        let now = Int64(Date().timeIntervalSince1970)
        return Track(
            fileURL: "file:///test.mp3",
            title: "Old Title",
            genre: "Rock",
            rating: 60,
            loved: false,
            addedAt: now,
            updatedAt: now
        )
    }

    @Test func isEmpty_whenNothingSet() {
        let patch = TrackTagPatch()
        #expect(patch.isEmpty)
    }

    @Test func notEmpty_whenTitleSet() {
        var patch = TrackTagPatch()
        patch.title = "New Title"
        #expect(!patch.isEmpty)
    }

    @Test func applyingTitle() {
        var patch = TrackTagPatch()
        patch.title = "New Title"
        let track = patch.applying(to: self.makeTrack())
        #expect(track.title == "New Title")
    }

    @Test func applyingDoesNotChangeMissingFields() {
        var patch = TrackTagPatch()
        patch.title = "New Title"
        let original = self.makeTrack()
        let updated = patch.applying(to: original)
        // genre should be unchanged
        #expect(updated.genre == original.genre)
    }

    @Test func applyingClearGenre() {
        var patch = TrackTagPatch()
        patch.genre = .some(nil) // clear
        let updated = patch.applying(to: self.makeTrack())
        #expect(updated.genre == nil)
    }

    @Test func applyingSetsUserEdited() {
        var patch = TrackTagPatch()
        patch.title = "Changed"
        let updated = patch.applying(to: self.makeTrack())
        #expect(updated.userEdited == true)
    }

    @Test func applyingRating() {
        var patch = TrackTagPatch()
        patch.rating = 80
        let updated = patch.applying(to: self.makeTrack())
        #expect(updated.rating == 80)
    }

    @Test func applyingLoved() {
        var patch = TrackTagPatch()
        patch.loved = true
        let updated = patch.applying(to: self.makeTrack())
        #expect(updated.loved == true)
    }

    @Test func applyingYear() {
        var patch = TrackTagPatch()
        patch.year = 2024
        let updated = patch.applying(to: self.makeTrack())
        #expect(updated.year == 2024)
        #expect(updated.yearText == "2024")
    }

    @Test func applyingClearYear() {
        var patch = TrackTagPatch()
        patch.year = .some(nil)
        let updated = patch.applying(to: self.makeTrack())
        #expect(updated.year == nil)
        #expect(updated.yearText == nil)
    }
}
