import Foundation
import Metadata
import Persistence

// MARK: - TagDiff

/// Computes a minimal `TrackTagPatch` by comparing before/after `TrackTags`.
///
/// Only fields that actually changed are included in the patch; unchanged
/// fields are left as `nil` (= "do not apply").
public enum TagDiff {
    /// Returns a patch containing only the fields that differ between `before` and `after`.
    public static func diff(before: TrackTags, after: TrackTags) -> TrackTagPatch {
        var patch = TrackTagPatch()

        // String fields: set patch field when the value changed.
        if before.title != after.title { patch.title = after.title }
        if before.artist != after.artist { patch.artist = after.artist }
        if before.albumArtist != after.albumArtist { patch.albumArtist = after.albumArtist }
        if before.album != after.album { patch.album = after.album }
        if before.genre != after.genre { patch.genre = after.genre }
        if before.composer != after.composer { patch.composer = after.composer }
        if before.comment != after.comment { patch.comment = after.comment }
        if before.key != after.key { patch.key = after.key }
        if before.isrc != after.isrc { patch.isrc = after.isrc }
        if before.lyrics != after.lyrics { patch.lyrics = after.lyrics }
        if before.sortArtist != after.sortArtist { patch.sortArtist = after.sortArtist }
        if before.sortAlbumArtist != after.sortAlbumArtist {
            patch.sortAlbumArtist = after.sortAlbumArtist
        }
        if before.sortAlbum != after.sortAlbum { patch.sortAlbum = after.sortAlbum }

        // Numeric fields
        if before.trackNumber != after.trackNumber { patch.trackNumber = after.trackNumber }
        if before.trackTotal != after.trackTotal { patch.trackTotal = after.trackTotal }
        if before.discNumber != after.discNumber { patch.discNumber = after.discNumber }
        if before.discTotal != after.discTotal { patch.discTotal = after.discTotal }
        if before.year != after.year { patch.year = after.year }
        if before.bpm != after.bpm { patch.bpm = after.bpm }

        // ReplayGain
        if before.replayGain.trackGain != after.replayGain.trackGain {
            patch.replaygainTrackGain = after.replayGain.trackGain
        }
        if before.replayGain.trackPeak != after.replayGain.trackPeak {
            patch.replaygainTrackPeak = after.replayGain.trackPeak
        }
        if before.replayGain.albumGain != after.replayGain.albumGain {
            patch.replaygainAlbumGain = after.replayGain.albumGain
        }
        if before.replayGain.albumPeak != after.replayGain.albumPeak {
            patch.replaygainAlbumPeak = after.replayGain.albumPeak
        }

        // Cover art: compare by SHA-256 hash of the first item
        let beforeHash = before.coverArt.first?.sha256
        let afterHash = after.coverArt.first?.sha256
        if beforeHash != afterHash {
            patch.coverArt = after.coverArt.first?.data
        }

        return patch
    }

    /// Merges `patches` into a single patch.
    ///
    /// Later patches take precedence over earlier ones (last-writer wins).
    public static func merge(_ patches: [TrackTagPatch]) -> TrackTagPatch {
        var result = TrackTagPatch()
        for patch in patches {
            if patch.title != nil { result.title = patch.title }
            if patch.artist != nil { result.artist = patch.artist }
            if patch.albumArtist != nil { result.albumArtist = patch.albumArtist }
            if patch.album != nil { result.album = patch.album }
            if patch.genre != nil { result.genre = patch.genre }
            if patch.composer != nil { result.composer = patch.composer }
            if patch.comment != nil { result.comment = patch.comment }
            if patch.trackNumber != nil { result.trackNumber = patch.trackNumber }
            if patch.trackTotal != nil { result.trackTotal = patch.trackTotal }
            if patch.discNumber != nil { result.discNumber = patch.discNumber }
            if patch.discTotal != nil { result.discTotal = patch.discTotal }
            if patch.year != nil { result.year = patch.year }
            if patch.bpm != nil { result.bpm = patch.bpm }
            if patch.key != nil { result.key = patch.key }
            if patch.isrc != nil { result.isrc = patch.isrc }
            if patch.lyrics != nil { result.lyrics = patch.lyrics }
            if patch.sortArtist != nil { result.sortArtist = patch.sortArtist }
            if patch.sortAlbumArtist != nil { result.sortAlbumArtist = patch.sortAlbumArtist }
            if patch.sortAlbum != nil { result.sortAlbum = patch.sortAlbum }
            if patch.coverArt != nil { result.coverArt = patch.coverArt }
            if patch.rating != nil { result.rating = patch.rating }
            if patch.loved != nil { result.loved = patch.loved }
            if patch.excludedFromShuffle != nil { result.excludedFromShuffle = patch.excludedFromShuffle }
            if patch.replaygainTrackGain != nil { result.replaygainTrackGain = patch.replaygainTrackGain }
            if patch.replaygainTrackPeak != nil { result.replaygainTrackPeak = patch.replaygainTrackPeak }
            if patch.replaygainAlbumGain != nil { result.replaygainAlbumGain = patch.replaygainAlbumGain }
            if patch.replaygainAlbumPeak != nil { result.replaygainAlbumPeak = patch.replaygainAlbumPeak }
        }
        return result
    }
}
