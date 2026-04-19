import GRDB

/// An album row in the `albums` table.
public struct Album: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    // MARK: - Table

    /// The database table name.
    public static let databaseTableName = "albums"

    // MARK: - Properties

    /// Auto-incremented row identifier; `nil` before first insertion.
    public var id: Int64?

    /// Album title.
    public var title: String

    /// Foreign key to the album-artist `artists` row.
    public var albumArtistID: Int64?

    /// Release year.
    public var year: Int?

    /// MusicBrainz release identifier.
    public var musicbrainzReleaseID: String?

    /// MusicBrainz release-group identifier (preferred for linking pressings).
    public var musicbrainzReleaseGroupID: String?

    /// Hash of the associated cover-art row.
    public var coverArtHash: String?

    /// Release type: `"album"`, `"ep"`, `"single"`, `"compilation"`, `"live"`.
    public var releaseType: String?

    /// Total number of tracks on the album (from tags).
    public var totalTracks: Int?

    /// Total number of discs on the album (from tags).
    public var totalDiscs: Int?

    /// Cached cover-art file path (may differ from `cover_art.path` if unlinked).
    public var coverArtPath: String?

    /// When `true`, `QueuePlayer` invokes `GaplessScheduler` for consecutive
    /// tracks on this album even when padding tags are absent.
    public var forceGapless: Bool

    // MARK: - Init

    // swiftlint:disable function_default_parameter_at_end
    /// Memberwise initialiser.
    public init(
        id: Int64? = nil,
        title: String,
        albumArtistID: Int64? = nil,
        year: Int? = nil,
        musicbrainzReleaseID: String? = nil,
        musicbrainzReleaseGroupID: String? = nil,
        coverArtHash: String? = nil,
        releaseType: String? = nil,
        totalTracks: Int? = nil,
        totalDiscs: Int? = nil,
        coverArtPath: String? = nil,
        forceGapless: Bool = false
    ) {
        self.id = id
        self.title = title
        self.albumArtistID = albumArtistID
        self.year = year
        self.musicbrainzReleaseID = musicbrainzReleaseID
        self.musicbrainzReleaseGroupID = musicbrainzReleaseGroupID
        self.coverArtHash = coverArtHash
        self.releaseType = releaseType
        self.totalTracks = totalTracks
        self.totalDiscs = totalDiscs
        self.coverArtPath = coverArtPath
        self.forceGapless = forceGapless
    }

    // swiftlint:enable function_default_parameter_at_end

    // MARK: - GRDB

    /// Captures the auto-incremented row ID after insertion.
    public mutating func didInsert(_ inserted: InsertionSuccess) {
        self.id = inserted.rowID
    }

    // MARK: - CodingKeys

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case albumArtistID = "album_artist_id"
        case year
        case musicbrainzReleaseID = "musicbrainz_release_id"
        case musicbrainzReleaseGroupID = "musicbrainz_release_group_id"
        case coverArtHash = "cover_art_hash"
        case releaseType = "release_type"
        case totalTracks = "total_tracks"
        case totalDiscs = "total_discs"
        case coverArtPath = "cover_art_path"
        case forceGapless = "force_gapless"
    }
}
