import Foundation

/// All metadata extracted from a single audio file.
public struct TrackTags: Sendable {
    // MARK: - Core tags

    public var title: String?
    public var artist: String?
    public var albumArtist: String?
    public var album: String?
    public var genre: String?
    public var composer: String?
    public var comment: String?
    public var year: Int?
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

    // MARK: - MusicBrainz identifiers

    public var musicbrainzTrackID: String?
    public var musicbrainzRecordingID: String?
    public var musicbrainzAlbumArtistID: String?
    public var musicbrainzReleaseID: String?
    public var musicbrainzReleaseGroupID: String?

    // MARK: - Loudness

    public var replayGain: ReplayGain

    // MARK: - Cover art (extracted, deduped)

    public var coverArt: [ExtractedCoverArt]

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
        musicbrainzTrackID: String? = nil,
        musicbrainzRecordingID: String? = nil,
        musicbrainzAlbumArtistID: String? = nil,
        musicbrainzReleaseID: String? = nil,
        musicbrainzReleaseGroupID: String? = nil,
        replayGain: ReplayGain = ReplayGain(),
        coverArt: [ExtractedCoverArt] = [],
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
        self.musicbrainzTrackID = musicbrainzTrackID
        self.musicbrainzRecordingID = musicbrainzRecordingID
        self.musicbrainzAlbumArtistID = musicbrainzAlbumArtistID
        self.musicbrainzReleaseID = musicbrainzReleaseID
        self.musicbrainzReleaseGroupID = musicbrainzReleaseGroupID
        self.replayGain = replayGain
        self.coverArt = coverArt
        self.duration = duration
        self.sampleRate = sampleRate
        self.bitrate = bitrate
        self.channels = channels
        self.bitDepth = bitDepth
    }
}
