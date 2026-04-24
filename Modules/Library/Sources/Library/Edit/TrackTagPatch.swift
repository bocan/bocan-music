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

    // MARK: - ReplayGain (Phase 9 hook)

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
            self.isrc == nil && self.lyrics == nil && self.sortArtist == nil &&
            self.sortAlbumArtist == nil && self.sortAlbum == nil && self.coverArt == nil &&
            self.rating == nil && self.loved == nil && self.excludedFromShuffle == nil &&
            self.replaygainTrackGain == nil && self.replaygainTrackPeak == nil &&
            self.replaygainAlbumGain == nil && self.replaygainAlbumPeak == nil
    }

    // MARK: - Apply to Track

    /// Returns a copy of `track` with all non-nil patch fields applied.
    ///
    /// Does NOT update artist/album foreign keys — callers must do the DB
    /// normalisation step separately (see `MetadataEditService`).
    public func applying(to track: Track) -> Track {
        var out = track
        let now = Int64(Date().timeIntervalSince1970)

        if let v = title { out.title = v }
        if let v = genre { out.genre = v }
        if let v = composer { out.composer = v }
        if let v = trackNumber { out.trackNumber = v }
        if let v = trackTotal { out.trackTotal = v }
        if let v = discNumber { out.discNumber = v }
        if let v = discTotal { out.discTotal = v }
        if let v = year { out.year = v
            out.yearText = v.map { String($0) }
        }
        if let v = bpm { out.bpm = v }
        if let v = key { out.key = v }
        if let v = isrc { out.isrc = v }
        if let v = rating { out.rating = v ?? 0 }
        if let v = loved { out.loved = v }
        if let v = excludedFromShuffle { out.excludedFromShuffle = v }
        if let v = replaygainTrackGain { out.replaygainTrackGain = v }
        if let v = replaygainTrackPeak { out.replaygainTrackPeak = v }
        if let v = replaygainAlbumGain { out.replaygainAlbumGain = v }
        if let v = replaygainAlbumPeak { out.replaygainAlbumPeak = v }

        out.userEdited = true
        out.updatedAt = now
        return out
    }
}
