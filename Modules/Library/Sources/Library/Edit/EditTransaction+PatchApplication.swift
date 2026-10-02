import Foundation
import Metadata

// MARK: - Patch application

extension EditTransaction {
    static func applyPatch(_ patch: TrackTagPatch, to tags: inout TrackTags) {
        self.applyTextFields(patch, to: &tags)
        self.applyNumberAndKeyFields(patch, to: &tags)
        self.applyMusicBrainzIDs(patch, to: &tags)
        self.applyLyricsSortAndGain(patch, to: &tags)
    }

    private static func applyTextFields(_ patch: TrackTagPatch, to tags: inout TrackTags) {
        if let title = patch.title {
            tags.title = title
        }
        if let artist = patch.artist {
            tags.artist = artist
        }
        if let albumArtist = patch.albumArtist {
            tags.albumArtist = albumArtist
        }
        if let album = patch.album {
            tags.album = album
        }
        if let genre = patch.genre {
            tags.genre = genre
        }
        if let composer = patch.composer {
            tags.composer = composer
        }
        if let comment = patch.comment {
            tags.comment = comment
        }
    }

    private static func applyNumberAndKeyFields(_ patch: TrackTagPatch, to tags: inout TrackTags) {
        if let trackNumber = patch.trackNumber {
            tags.trackNumber = trackNumber
        }
        if let trackTotal = patch.trackTotal {
            tags.trackTotal = trackTotal
        }
        if let discNumber = patch.discNumber {
            tags.discNumber = discNumber
        }
        if let discTotal = patch.discTotal {
            tags.discTotal = discTotal
        }
        if let year = patch.year {
            tags.year = year
        }
        if let bpm = patch.bpm {
            tags.bpm = bpm
        }
        if let key = patch.key {
            tags.key = key
        }
        if let isrc = patch.isrc {
            tags.isrc = isrc
        }
    }

    private static func applyMusicBrainzIDs(_ patch: TrackTagPatch, to tags: inout TrackTags) {
        if let musicbrainzTrackID = patch.musicbrainzTrackID {
            tags.musicbrainzTrackID = musicbrainzTrackID
        }
        if let musicbrainzRecordingID = patch.musicbrainzRecordingID {
            tags.musicbrainzRecordingID = musicbrainzRecordingID
        }
        if let musicbrainzReleaseID = patch.musicbrainzReleaseID {
            tags.musicbrainzReleaseID = musicbrainzReleaseID
        }
        if let musicbrainzReleaseGroupID = patch.musicbrainzReleaseGroupID {
            tags.musicbrainzReleaseGroupID = musicbrainzReleaseGroupID
        }
        if let musicbrainzArtistID = patch.musicbrainzArtistID {
            tags.musicbrainzArtistID = musicbrainzArtistID
        }
        if let musicbrainzAlbumArtistID = patch.musicbrainzAlbumArtistID {
            tags.musicbrainzAlbumArtistID = musicbrainzAlbumArtistID
        }
    }

    private static func applyLyricsSortAndGain(_ patch: TrackTagPatch, to tags: inout TrackTags) {
        if let lyrics = patch.lyrics {
            tags.lyrics = lyrics
        }
        // syncedLyrics writes to the same audio-file tag as plain lyrics;
        // the isSynced distinction is maintained in the lyrics DB table only.
        if let syncedLyrics = patch.syncedLyrics {
            tags.lyrics = syncedLyrics
        }
        if let sortArtist = patch.sortArtist {
            tags.sortArtist = sortArtist
        }
        if let sortAlbumArtist = patch.sortAlbumArtist {
            tags.sortAlbumArtist = sortAlbumArtist
        }
        if let sortAlbum = patch.sortAlbum {
            tags.sortAlbum = sortAlbum
        }
        if let trackGain = patch.replaygainTrackGain {
            let rg = tags.replayGain
            tags.replayGain = ReplayGain(
                trackGain: trackGain,
                trackPeak: rg.trackPeak,
                albumGain: rg.albumGain,
                albumPeak: rg.albumPeak
            )
        }
    }

    /// Detects the MIME type of image `data` from its magic bytes.
    ///
    /// Returns `"image/jpeg"` as the default for unrecognised formats because
    /// `ArtworkEditor.normalise()` converts large images to JPEG, making JPEG
    /// the most common format for patched cover art.
    static func mimeType(for data: Data) -> String {
        guard data.count >= 4 else { return "image/jpeg" }
        let header = data.prefix(4)
        // PNG: 89 50 4E 47
        if header.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return "image/png"
        }
        // JPEG: FF D8 FF
        if header.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "image/jpeg"
        }
        // WebP: 52 49 46 46 ... 57 45 42 50 (need 12 bytes)
        if data.count >= 12, header.starts(with: [0x52, 0x49, 0x46, 0x46]),
           data[8 ..< 12].elementsEqual([0x57, 0x45, 0x42, 0x50]) {
            return "image/webp"
        }
        return "image/jpeg"
    }
}
