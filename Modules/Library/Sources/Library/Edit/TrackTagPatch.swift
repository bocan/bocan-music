import Foundation
import Persistence

// MARK: - TrackTagPatch

/// A minimal diff of tag changes to apply to one or more tracks.
///
/// - `nil` outer value means "leave this field unchanged".
/// - `.some(nil)` (written as `Optional<Optional<T>>.some(nil)`) means "clear this field".
/// - `.some(.some(v))` means "set this field to v".
///
/// Use `TagDiff` to produce a patch from before/after `TrackTags`, or build one
/// manually for UI-driven single/multi-edit flows.
public struct TrackTagPatch: Sendable, Codable, Hashable {
    // MARK: - Core text tags

    public var title: String??
    public var artist: String??
    public var albumArtist: String??
    public var album: String??
    public var genre: String??
    public var composer: String??
    public var comment: String??

    // MARK: - Numeric tags

    public var trackNumber: Int??
    public var trackTotal: Int??
    public var discNumber: Int??
    public var discTotal: Int??
    public var year: Int??

    // MARK: - Extended tags

    public var bpm: Double??
    public var key: String??
    public var isrc: String??
    public var lyrics: String??
    /// LRC-formatted synced lyrics text. When set, the lyrics DB row will be
    /// saved with `isSynced = true`. Set `lyrics` to `.some(nil)` when providing
    /// `syncedLyrics` to avoid conflicting writes.
    public var syncedLyrics: String??

    // MARK: - MusicBrainz identifiers (ADR-012)

    public var musicbrainzTrackID: String??
    public var musicbrainzRecordingID: String??
    public var musicbrainzReleaseID: String??
    public var musicbrainzReleaseGroupID: String??
    public var musicbrainzArtistID: String??
    public var musicbrainzAlbumArtistID: String??

    // MARK: - Sort tags

    public var sortArtist: String??
    public var sortAlbumArtist: String??
    public var sortAlbum: String??

    // MARK: - Cover art (raw bytes; `.some(nil)` = remove)

    public var coverArt: Data??

    // MARK: - Player state

    /// 0–100 rating. `nil` = no rating set (distinct from rating 0).
    public var rating: Int??
    public var loved: Bool?
    public var excludedFromShuffle: Bool?

    // MARK: - ReplayGain (ADR-013 hook)

    public var replaygainTrackGain: Double??
    public var replaygainTrackPeak: Double??
    public var replaygainAlbumGain: Double??
    public var replaygainAlbumPeak: Double??

    // MARK: - Init

    public init(
        title: String?? = nil,
        artist: String?? = nil,
        albumArtist: String?? = nil,
        album: String?? = nil,
        genre: String?? = nil,
        composer: String?? = nil,
        comment: String?? = nil,
        trackNumber: Int?? = nil,
        trackTotal: Int?? = nil,
        discNumber: Int?? = nil,
        discTotal: Int?? = nil,
        year: Int?? = nil,
        bpm: Double?? = nil,
        key: String?? = nil,
        isrc: String?? = nil,
        lyrics: String?? = nil,
        syncedLyrics: String?? = nil,
        musicbrainzTrackID: String?? = nil,
        musicbrainzRecordingID: String?? = nil,
        musicbrainzReleaseID: String?? = nil,
        musicbrainzReleaseGroupID: String?? = nil,
        musicbrainzArtistID: String?? = nil,
        musicbrainzAlbumArtistID: String?? = nil,
        sortArtist: String?? = nil,
        sortAlbumArtist: String?? = nil,
        sortAlbum: String?? = nil,
        coverArt: Data?? = nil,
        rating: Int?? = nil,
        loved: Bool? = nil,
        excludedFromShuffle: Bool? = nil,
        replaygainTrackGain: Double?? = nil,
        replaygainTrackPeak: Double?? = nil,
        replaygainAlbumGain: Double?? = nil,
        replaygainAlbumPeak: Double?? = nil
    ) {
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist
        self.album = album
        self.genre = genre
        self.composer = composer
        self.comment = comment
        self.trackNumber = trackNumber
        self.trackTotal = trackTotal
        self.discNumber = discNumber
        self.discTotal = discTotal
        self.year = year
        self.bpm = bpm
        self.key = key
        self.isrc = isrc
        self.lyrics = lyrics
        self.syncedLyrics = syncedLyrics
        self.musicbrainzTrackID = musicbrainzTrackID
        self.musicbrainzRecordingID = musicbrainzRecordingID
        self.musicbrainzReleaseID = musicbrainzReleaseID
        self.musicbrainzReleaseGroupID = musicbrainzReleaseGroupID
        self.musicbrainzArtistID = musicbrainzArtistID
        self.musicbrainzAlbumArtistID = musicbrainzAlbumArtistID
        self.sortArtist = sortArtist
        self.sortAlbumArtist = sortAlbumArtist
        self.sortAlbum = sortAlbum
        self.coverArt = coverArt
        self.rating = rating
        self.loved = loved
        self.excludedFromShuffle = excludedFromShuffle
        self.replaygainTrackGain = replaygainTrackGain
        self.replaygainTrackPeak = replaygainTrackPeak
        self.replaygainAlbumGain = replaygainAlbumGain
        self.replaygainAlbumPeak = replaygainAlbumPeak
    }

    // MARK: - Helpers

    /// `true` when no field in the patch carries a change.
    public var isEmpty: Bool {
        self.title == nil && self.artist == nil && self.albumArtist == nil &&
            self.album == nil && self.genre == nil && self.composer == nil && self.comment == nil &&
            self.trackNumber == nil && self.trackTotal == nil && self.discNumber == nil &&
            self.discTotal == nil && self.year == nil && self.bpm == nil && self.key == nil &&
            self.isrc == nil && self.lyrics == nil && self.syncedLyrics == nil &&
            self.musicbrainzTrackID == nil && self.musicbrainzRecordingID == nil &&
            self.musicbrainzReleaseID == nil && self.musicbrainzReleaseGroupID == nil &&
            self.musicbrainzArtistID == nil &&
            self.musicbrainzAlbumArtistID == nil &&
            self.sortArtist == nil &&
            self.sortAlbumArtist == nil && self.sortAlbum == nil && self.coverArt == nil &&
            self.rating == nil && self.loved == nil && self.excludedFromShuffle == nil &&
            self.replaygainTrackGain == nil && self.replaygainTrackPeak == nil &&
            self.replaygainAlbumGain == nil && self.replaygainAlbumPeak == nil
    }

    /// `true` when the patch changes at least one tag that lives in the audio
    /// file itself.
    ///
    /// Cover art is deliberately not counted: it reaches the file only when the
    /// user switches embedding on. The rating, loved and shuffle flags never
    /// leave the database. A patch that touches none of these needs no file
    /// write at all, so the edit skips the backup, the TagLib rewrite and the
    /// re-read (#472).
    public var touchesFileTags: Bool {
        self.title != nil || self.artist != nil || self.albumArtist != nil ||
            self.album != nil || self.genre != nil || self.composer != nil || self.comment != nil ||
            self.trackNumber != nil || self.trackTotal != nil || self.discNumber != nil ||
            self.discTotal != nil || self.year != nil || self.bpm != nil || self.key != nil ||
            self.isrc != nil || self.lyrics != nil || self.syncedLyrics != nil ||
            self.musicbrainzTrackID != nil || self.musicbrainzRecordingID != nil ||
            self.musicbrainzReleaseID != nil || self.musicbrainzReleaseGroupID != nil ||
            self.musicbrainzArtistID != nil || self.musicbrainzAlbumArtistID != nil ||
            self.sortArtist != nil || self.sortAlbumArtist != nil || self.sortAlbum != nil ||
            self.replaygainTrackGain != nil || self.replaygainTrackPeak != nil ||
            self.replaygainAlbumGain != nil || self.replaygainAlbumPeak != nil
    }

    // MARK: - Apply to Track

    /// Returns a copy of `track` with all non-nil patch fields applied.
    ///
    /// Does NOT update artist/album foreign keys — callers must do the DB
    /// normalisation step separately (see `MetadataEditService`).
    public func applying(to track: Track) -> Track {
        var out = track
        let now = Int64(Date().timeIntervalSince1970)

        self.applyTitleAndNumbers(to: &out)
        self.applyYearAndKeyFields(to: &out)
        self.applyMusicBrainzIDs(to: &out)
        self.applyUserStateAndGain(to: &out)

        out.userEdited = true
        out.updatedAt = now
        return out
    }

    private func applyTitleAndNumbers(to out: inout Track) {
        if let title = self.title {
            out.title = title
        }
        if let genre = self.genre {
            out.genre = genre
        }
        if let composer = self.composer {
            out.composer = composer
        }
        if let trackNumber = self.trackNumber {
            out.trackNumber = trackNumber
        }
        if let trackTotal = self.trackTotal {
            out.trackTotal = trackTotal
        }
        if let discNumber = self.discNumber {
            out.discNumber = discNumber
        }
        if let discTotal = self.discTotal {
            out.discTotal = discTotal
        }
    }

    private func applyYearAndKeyFields(to out: inout Track) {
        if let year = self.year {
            out.year = year
            out.yearText = year.map { String($0) }
        }
        if let bpm = self.bpm {
            out.bpm = bpm
        }
        if let key = self.key {
            out.key = key
        }
        if let isrc = self.isrc {
            out.isrc = isrc
        }
    }

    private func applyMusicBrainzIDs(to out: inout Track) {
        if let musicbrainzTrackID = self.musicbrainzTrackID {
            out.musicbrainzTrackID = musicbrainzTrackID
        }
        if let musicbrainzRecordingID = self.musicbrainzRecordingID {
            out.musicbrainzRecordingID = musicbrainzRecordingID
        }
        if let musicbrainzReleaseID = self.musicbrainzReleaseID {
            out.musicbrainzReleaseID = musicbrainzReleaseID
        }
        if let musicbrainzReleaseGroupID = self.musicbrainzReleaseGroupID {
            out.musicbrainzReleaseGroupID = musicbrainzReleaseGroupID
        }
        if let musicbrainzArtistID = self.musicbrainzArtistID {
            out.musicbrainzArtistID = musicbrainzArtistID
        }
        if let musicbrainzAlbumArtistID = self.musicbrainzAlbumArtistID {
            out.musicbrainzAlbumArtistID = musicbrainzAlbumArtistID
        }
    }

    private func applyUserStateAndGain(to out: inout Track) {
        if let rating = self.rating {
            out.rating = rating ?? 0
        }
        if let loved = self.loved {
            out.loved = loved
        }
        if let excludedFromShuffle = self.excludedFromShuffle {
            out.excludedFromShuffle = excludedFromShuffle
        }
        if let replaygainTrackGain = self.replaygainTrackGain {
            out.replaygainTrackGain = replaygainTrackGain
        }
        if let replaygainTrackPeak = self.replaygainTrackPeak {
            out.replaygainTrackPeak = replaygainTrackPeak
        }
        if let replaygainAlbumGain = self.replaygainAlbumGain {
            out.replaygainAlbumGain = replaygainAlbumGain
        }
        if let replaygainAlbumPeak = self.replaygainAlbumPeak {
            out.replaygainAlbumPeak = replaygainAlbumPeak
        }
    }
}
