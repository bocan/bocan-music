import GRDB

/// An artist row in the `artists` table.
public struct Artist: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    // MARK: - Table

    /// The database table name.
    public static let databaseTableName = "artists"

    // MARK: - Properties

    /// Auto-incremented row identifier; `nil` before first insertion.
    public var id: Int64?

    /// Display name of the artist.
    public var name: String

    /// Sort-normalised name (e.g. `"Beatles, The"`).
    public var sortName: String?

    /// MusicBrainz artist identifier.
    public var musicbrainzArtistID: String?

    /// MusicBrainz disambiguation string (e.g. `"guitarist"` vs `"composer"`).
    public var disambiguation: String?

    // MARK: - Init

    // swiftlint:disable function_default_parameter_at_end
    /// Memberwise initialiser.
    public init(
        id: Int64? = nil,
        name: String,
        sortName: String? = nil,
        musicbrainzArtistID: String? = nil,
        disambiguation: String? = nil
    ) {
        self.id = id
        self.name = name
        self.sortName = sortName
        self.musicbrainzArtistID = musicbrainzArtistID
        self.disambiguation = disambiguation
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
        case name
        case sortName = "sort_name"
        case musicbrainzArtistID = "musicbrainz_artist_id"
        case disambiguation
    }
}
