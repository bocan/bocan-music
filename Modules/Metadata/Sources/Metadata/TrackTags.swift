import Foundation

/// All metadata extracted from a single audio file.
public struct TrackTags: Sendable {
    // MARK: - Core tags

    public var title: String?
    public var artist: String?
    public var albumArtist: String?
    public var album: String?
    /// `true` when the file carries a set compilation flag (ID3 `TCMP`, MP4
    /// `cpil`, or Vorbis `COMPILATION`). Used to group multi-artist
    /// compilations under a single album even without an album-artist tag.
    public var isCompilation: Bool
    public var genre: String?
    public var composer: String?
    public var comment: String?
    public var year: Int?
    public var dateText: String?
    public var trackNumber: Int?
    public var trackTotal: Int?
    public var discNumber: Int?
    public var discTotal: Int?

    // MARK: - Sort tags

    public var sortTitle: String?
    public var sortArtist: String?
    public var sortAlbumArtist: String?
    public var sortAlbum: String?

    // MARK: - Extended tags

    public var lyrics: String?
    public var bpm: Double?
    public var key: String?
    public var isrc: String?
    /// MusicBrainz release-group primary type from RELEASETYPE (`album`, `single`, `ep`, ...), lowercased.
    public var releaseType: String?

    // MARK: - MusicBrainz identifiers

    public var musicbrainzTrackID: String?
    public var musicbrainzRecordingID: String?
    /// MusicBrainz track-artist identifier (`MUSICBRAINZ_ARTISTID`, first value when multi-valued).
    public var musicbrainzArtistID: String?
    public var musicbrainzAlbumArtistID: String?
    public var musicbrainzReleaseID: String?
    public var musicbrainzReleaseGroupID: String?

    // MARK: - Loudness

    public var replayGain: ReplayGain

    // MARK: - Cover art (extracted, deduped)

    public var coverArt: [ExtractedCoverArt]

    // MARK: - Multi-valued tags

    /// Full TagLib `PropertyMap` lifted into Swift: each key may carry
    /// multiple values (Vorbis comments / ID3v2.4). The flat fields above
    /// hold only the first value of each tag.
    public var extendedTags: [String: [String]]

    // MARK: - Audio properties

    public var duration: Double
    public var sampleRate: Int?
    public var bitrate: Int?
    public var channels: Int?
    public var bitDepth: Int?

    // MARK: - Init

    public init(
        title: String? = nil,
        artist: String? = nil,
        albumArtist: String? = nil,
        album: String? = nil,
        isCompilation: Bool = false,
        genre: String? = nil,
        composer: String? = nil,
        comment: String? = nil,
        year: Int? = nil,
        trackNumber: Int? = nil,
        trackTotal: Int? = nil,
        discNumber: Int? = nil,
        discTotal: Int? = nil,
        sortTitle: String? = nil,
        sortArtist: String? = nil,
        sortAlbumArtist: String? = nil,
        sortAlbum: String? = nil,
        lyrics: String? = nil,
        bpm: Double? = nil,
        key: String? = nil,
        isrc: String? = nil,
        releaseType: String? = nil,
        musicbrainzTrackID: String? = nil,
        musicbrainzRecordingID: String? = nil,
        musicbrainzArtistID: String? = nil,
        musicbrainzAlbumArtistID: String? = nil,
        musicbrainzReleaseID: String? = nil,
        musicbrainzReleaseGroupID: String? = nil,
        replayGain: ReplayGain = ReplayGain(),
        coverArt: [ExtractedCoverArt] = [],
        extendedTags: [String: [String]] = [:],
        duration: Double = 0,
        sampleRate: Int? = nil,
        bitrate: Int? = nil,
        channels: Int? = nil,
        bitDepth: Int? = nil
    ) {
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist
        self.album = album
        self.isCompilation = isCompilation
        self.genre = genre
        self.composer = composer
        self.comment = comment
        self.year = year
        self.trackNumber = trackNumber
        self.trackTotal = trackTotal
        self.discNumber = discNumber
        self.discTotal = discTotal
        self.sortTitle = sortTitle
        self.sortArtist = sortArtist
        self.sortAlbumArtist = sortAlbumArtist
        self.sortAlbum = sortAlbum
        self.lyrics = lyrics
        self.bpm = bpm
        self.key = key
        self.isrc = isrc
        self.releaseType = releaseType
        self.musicbrainzTrackID = musicbrainzTrackID
        self.musicbrainzRecordingID = musicbrainzRecordingID
        self.musicbrainzArtistID = musicbrainzArtistID
        self.musicbrainzAlbumArtistID = musicbrainzAlbumArtistID
        self.musicbrainzReleaseID = musicbrainzReleaseID
        self.musicbrainzReleaseGroupID = musicbrainzReleaseGroupID
        self.replayGain = replayGain
        self.coverArt = coverArt
        self.extendedTags = extendedTags
        self.duration = duration
        self.sampleRate = sampleRate
        self.bitrate = bitrate
        self.channels = channels
        self.bitDepth = bitDepth
    }
}

// MARK: - Release type selection

public extension TrackTags {
    /// MusicBrainz release-group primary types, in preference order.
    static let primaryReleaseTypes: [String] = ["album", "single", "ep", "broadcast", "other"]

    /// MusicBrainz secondary types, accepted when no primary type is present.
    static let secondaryReleaseTypes: [String] = [
        "compilation", "soundtrack", "spokenword", "interview", "audiobook", "audio drama",
        "live", "remix", "dj-mix", "mixtape/street", "demo", "field recording",
    ]

    /// Picks the release type from a multi-valued RELEASETYPE list.
    ///
    /// Picard writes the primary type first, but some taggers write junk
    /// (a real library had `["ELEAS", "album", "compilation"]` on 81 files
    /// and `["ELEAS"]` alone on 76 more), so prefer a known primary type
    /// anywhere in the list, then a known secondary, and otherwise nil: the
    /// MusicBrainz vocabulary is closed, so an unknown value is never a type
    /// worth storing (#403).
    static func primaryReleaseType(from values: [String]) -> String? {
        let lowered = values.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        if let primary = lowered.first(where: { self.primaryReleaseTypes.contains($0) }) { return primary }
        return lowered.first(where: { self.secondaryReleaseTypes.contains($0) })
    }
}
