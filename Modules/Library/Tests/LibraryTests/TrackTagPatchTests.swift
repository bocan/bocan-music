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

    // MARK: - File-tag classification (#472)

    /// The fields that never reach the audio file: cover art goes there only
    /// when the user switches embedding on, and the other three are database
    /// columns with no tag behind them.
    private static let databaseOnlyFields: Set = [
        "coverArt", "rating", "loved", "excludedFromShuffle",
    ]

    /// `touchesFileTags` is a second list of the fields `applyPatch` writes into
    /// the file, and a new field that nobody adds to it would silently stop
    /// being written. This pins the whole set, so adding a field fails here
    /// until it is classified one way or the other.
    @Test func everyPatchFieldIsClassifiedAsFileTagOrDatabaseOnly() {
        let all = TrackTagPatch(
            title: "t", artist: "a", albumArtist: "aa", album: "al", genre: "g",
            composer: "c", comment: "cm", trackNumber: 1, trackTotal: 2,
            discNumber: 1, discTotal: 2, year: 2024, bpm: 120, key: "Am",
            isrc: "i", lyrics: "l", syncedLyrics: "sl", musicbrainzTrackID: "1",
            musicbrainzRecordingID: "2", musicbrainzReleaseID: "3",
            musicbrainzReleaseGroupID: "4", musicbrainzArtistID: "5",
            musicbrainzAlbumArtistID: "6", sortArtist: "sa", sortAlbumArtist: "saa",
            sortAlbum: "sal", coverArt: Data([0x01]), rating: 80, loved: true,
            excludedFromShuffle: true, replaygainTrackGain: -3.5,
            replaygainTrackPeak: 0.9, replaygainAlbumGain: -4.5, replaygainAlbumPeak: 0.8
        )
        let fields = Set(Mirror(reflecting: all).children.compactMap(\.label))
        let known = Self.databaseOnlyFields.union([
            "title", "artist", "albumArtist", "album", "genre", "composer", "comment",
            "trackNumber", "trackTotal", "discNumber", "discTotal", "year", "bpm", "key",
            "isrc", "lyrics", "syncedLyrics", "musicbrainzTrackID", "musicbrainzRecordingID",
            "musicbrainzReleaseID", "musicbrainzReleaseGroupID", "musicbrainzArtistID",
            "musicbrainzAlbumArtistID", "sortArtist", "sortAlbumArtist", "sortAlbum",
            "replaygainTrackGain", "replaygainTrackPeak", "replaygainAlbumGain",
            "replaygainAlbumPeak",
        ])
        #expect(fields == known, "a new patch field needs a decision in touchesFileTags")
        #expect(all.touchesFileTags)
    }

    @Test func aPatchOfDatabaseOnlyFieldsTouchesNoFileTag() {
        var patch = TrackTagPatch()
        patch.coverArt = Data([0x01])
        patch.rating = 80
        patch.loved = true
        patch.excludedFromShuffle = true
        #expect(!patch.isEmpty)
        #expect(!patch.touchesFileTags, "none of these live in the file")
    }

    @Test func aLyricChangeTouchesFileTags() {
        var patch = TrackTagPatch()
        patch.syncedLyrics = "[00:01.00]word"
        #expect(patch.touchesFileTags)
    }
}
