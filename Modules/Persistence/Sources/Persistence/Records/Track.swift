import Foundation
import GRDB

/// A music track row in the `tracks` table.
///
/// All timestamp columns (`added_at`, `updated_at`, `last_played_at`) are stored as
/// Unix epoch seconds (`Int64`).  `rating` is 0–100 for future half-star UI support.
/// `file_url` is stored as a Unicode-normalised (`precomposedStringWithCanonicalMapping`)
/// string to avoid phantom duplicates on APFS.
public struct Track: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    // MARK: - Table

    /// The database table name.
    public static let databaseTableName = "tracks"

    // MARK: - Primary key

    /// Auto-incremented row identifier; `nil` before first insertion.
    public var id: Int64?

    // MARK: - File properties

    /// Normalised file URL string (UNIQUE constraint).
    public var fileURL: String

    /// Security-scoped bookmark data for sandboxed file access.
    public var fileBookmark: Data?

    /// File size in bytes.
    public var fileSize: Int64

    /// File modification time (Unix epoch seconds).
    public var fileMtime: Int64

    /// Audio format identifier (e.g. `"flac"`, `"mp3"`).
    public var fileFormat: String

    // MARK: - Audio properties

    /// Playback duration in seconds.
    public var duration: Double

    /// Sample rate in Hz.
    public var sampleRate: Int?

    /// Bit depth.
    public var bitDepth: Int?

    /// Bitrate in kbps.
    public var bitrate: Int?

    /// Number of audio channels.
    public var channelCount: Int?

    /// Whether the format is losslessly encoded.
    public var isLossless: Bool?

    // MARK: - Core tags

    /// Track title.
    public var title: String?

    /// Foreign key to the performing `artists` row.
    public var artistID: Int64?

    /// Foreign key to the album-artist `artists` row.
    public var albumArtistID: Int64?

    /// Foreign key to the `albums` row.
    public var albumID: Int64?

    /// Track number within the disc.
    public var trackNumber: Int?

    /// Total tracks on the disc (added in M002).
    public var trackTotal: Int?

    /// Disc number within the album.
    public var discNumber: Int?

    /// Total discs in the release (added in M002).
    public var discTotal: Int?

    /// Release year.
    public var year: Int?

    /// Genre string.
    public var genre: String?

    /// Composer string.
    public var composer: String?

    // MARK: - Extended tags

    /// Beats per minute.
    public var bpm: Double?

    /// Musical key.
    public var key: String?

    /// International Standard Recording Code.
    public var isrc: String?

    /// MusicBrainz track identifier.
    public var musicbrainzTrackID: String?

    /// MusicBrainz recording identifier.
    public var musicbrainzRecordingID: String?

    /// MusicBrainz album-artist identifier (added in M002).
    public var musicbrainzAlbumArtistID: String?

    /// MusicBrainz release identifier (added in M002).
    public var musicbrainzReleaseID: String?

    /// MusicBrainz release-group identifier (added in M002).
    public var musicbrainzReleaseGroupID: String?

    /// ReplayGain track gain in dB.
    public var replaygainTrackGain: Double?

    /// ReplayGain track peak level.
    public var replaygainTrackPeak: Double?

    /// ReplayGain album gain in dB.
    public var replaygainAlbumGain: Double?

    /// ReplayGain album peak level.
    public var replaygainAlbumPeak: Double?

    // MARK: - Player state

    /// Number of complete plays.
    public var playCount: Int

    /// Number of skips.
    public var skipCount: Int

    /// Unix timestamp of the last play.
    public var lastPlayedAt: Int64?

    /// User rating, 0–100.
    public var rating: Int

    /// Whether the user has loved this track.
    public var loved: Bool

    /// Whether the track is excluded from shuffle.
    public var excludedFromShuffle: Bool

    // MARK: - Phase-2 additions

    /// Total seconds of audio played (for scrobbling heuristics).
    public var playDurationTotal: Double

    /// Seconds-elapsed at last skip (for smart-shuffle weighting).
    public var skipAfterSeconds: Double?

    /// Human-readable file path for display (denormalised from bookmark).
    public var filePathDisplay: String?

    /// Optional SHA-256 of audio frames for duplicate detection.
    public var contentHash: String?

    /// Soft-delete flag; preserves play counts for missing files.
    public var disabled: Bool

    /// Set to `true` when the user has manually edited tags; prevents rescan from overwriting.
    public var userEdited: Bool

    /// Stable sort key: `printf('%02d.%04d', disc_number, track_number)`.
    public var albumTrackSortKey: String?

    /// Foreign key to the `cover_art` row.
    public var coverArtHash: String?

    // MARK: - Bookkeeping

    /// Unix timestamp when the track was added to the library.
    public var addedAt: Int64

    /// Unix timestamp of the last metadata update.
    public var updatedAt: Int64

    // MARK: - Init

    // swiftlint:disable function_default_parameter_at_end
    public init(
        id: Int64? = nil,
        fileURL: String,
        fileBookmark: Data? = nil,
        fileSize: Int64 = 0,
        fileMtime: Int64 = 0,
        fileFormat: String = "",
        duration: Double = 0,
        sampleRate: Int? = nil,
        bitDepth: Int? = nil,
        bitrate: Int? = nil,
        channelCount: Int? = nil,
        isLossless: Bool? = nil,
        title: String? = nil,
        artistID: Int64? = nil,
        albumArtistID: Int64? = nil,
        albumID: Int64? = nil,
        trackNumber: Int? = nil,
        trackTotal: Int? = nil,
        discNumber: Int? = nil,
        discTotal: Int? = nil,
        year: Int? = nil,
        genre: String? = nil,
        composer: String? = nil,
        bpm: Double? = nil,
        key: String? = nil,
        isrc: String? = nil,
        musicbrainzTrackID: String? = nil,
        musicbrainzRecordingID: String? = nil,
        musicbrainzAlbumArtistID: String? = nil,
        musicbrainzReleaseID: String? = nil,
        musicbrainzReleaseGroupID: String? = nil,
        replaygainTrackGain: Double? = nil,
        replaygainTrackPeak: Double? = nil,
        replaygainAlbumGain: Double? = nil,
        replaygainAlbumPeak: Double? = nil,
        playCount: Int = 0,
        skipCount: Int = 0,
        lastPlayedAt: Int64? = nil,
        rating: Int = 0,
        loved: Bool = false,
        excludedFromShuffle: Bool = false,
        playDurationTotal: Double = 0,
        skipAfterSeconds: Double? = nil,
        filePathDisplay: String? = nil,
        contentHash: String? = nil,
        disabled: Bool = false,
        userEdited: Bool = false,
        albumTrackSortKey: String? = nil,
        coverArtHash: String? = nil,
        addedAt: Int64,
        updatedAt: Int64
    ) {
        self.id = id
        self.fileURL = fileURL
        self.fileBookmark = fileBookmark
        self.fileSize = fileSize
        self.fileMtime = fileMtime
        self.fileFormat = fileFormat
        self.duration = duration
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.bitrate = bitrate
        self.channelCount = channelCount
        self.isLossless = isLossless
        self.title = title
        self.artistID = artistID
        self.albumArtistID = albumArtistID
        self.albumID = albumID
        self.trackNumber = trackNumber
        self.trackTotal = trackTotal
        self.discNumber = discNumber
        self.discTotal = discTotal
        self.year = year
        self.genre = genre
        self.composer = composer
        self.bpm = bpm
        self.key = key
        self.isrc = isrc
        self.musicbrainzTrackID = musicbrainzTrackID
        self.musicbrainzRecordingID = musicbrainzRecordingID
        self.musicbrainzAlbumArtistID = musicbrainzAlbumArtistID
        self.musicbrainzReleaseID = musicbrainzReleaseID
        self.musicbrainzReleaseGroupID = musicbrainzReleaseGroupID
        self.replaygainTrackGain = replaygainTrackGain
        self.replaygainTrackPeak = replaygainTrackPeak
        self.replaygainAlbumGain = replaygainAlbumGain
        self.replaygainAlbumPeak = replaygainAlbumPeak
        self.playCount = playCount
        self.skipCount = skipCount
        self.lastPlayedAt = lastPlayedAt
        self.rating = rating
        self.loved = loved
        self.excludedFromShuffle = excludedFromShuffle
        self.playDurationTotal = playDurationTotal
        self.skipAfterSeconds = skipAfterSeconds
        self.filePathDisplay = filePathDisplay
        self.contentHash = contentHash
        self.disabled = disabled
        self.userEdited = userEdited
        self.albumTrackSortKey = albumTrackSortKey
        self.coverArtHash = coverArtHash
        self.addedAt = addedAt
        self.updatedAt = updatedAt
    }

    // swiftlint:enable function_default_parameter_at_end

    // MARK: - GRDB

    /// Captures the auto-incremented row ID after insertion.
    public mutating func didInsert(_ inserted: InsertionSuccess) {
        self.id = inserted.rowID
    }

    // MARK: - CodingKeys (column name mapping)

    private enum CodingKeys: String, CodingKey {
        case id
        case fileURL = "file_url"
        case fileBookmark = "file_bookmark"
        case fileSize = "file_size"
        case fileMtime = "file_mtime"
        case fileFormat = "file_format"
        case duration
        case sampleRate = "sample_rate"
        case bitDepth = "bit_depth"
        case bitrate
        case channelCount = "channel_count"
        case isLossless = "is_lossless"
        case title
        case artistID = "artist_id"
        case albumArtistID = "album_artist_id"
        case albumID = "album_id"
        case trackNumber = "track_number"
        case trackTotal = "track_total"
        case discNumber = "disc_number"
        case discTotal = "disc_total"
        case year
        case genre
        case composer
        case bpm
        case key
        case isrc
        case musicbrainzTrackID = "musicbrainz_track_id"
        case musicbrainzRecordingID = "musicbrainz_recording_id"
        case musicbrainzAlbumArtistID = "musicbrainz_album_artist_id"
        case musicbrainzReleaseID = "musicbrainz_release_id"
        case musicbrainzReleaseGroupID = "musicbrainz_release_group_id"
        case replaygainTrackGain = "replaygain_track_gain"
        case replaygainTrackPeak = "replaygain_track_peak"
        case replaygainAlbumGain = "replaygain_album_gain"
        case replaygainAlbumPeak = "replaygain_album_peak"
        case playCount = "play_count"
        case skipCount = "skip_count"
        case lastPlayedAt = "last_played_at"
        case rating
        case loved
        case excludedFromShuffle = "excluded_from_shuffle"
        case playDurationTotal = "play_duration_total"
        case skipAfterSeconds = "skip_after_seconds"
        case filePathDisplay = "file_path_display"
        case contentHash = "content_hash"
        case disabled
        case userEdited = "user_edited"
        case albumTrackSortKey = "album_track_sort_key"
        case coverArtHash = "cover_art_hash"
        case addedAt = "added_at"
        case updatedAt = "updated_at"
    }
}
