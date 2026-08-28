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

    /// Unix seconds of the last MusicBrainz artist lookup (#401); NULL = never.
    public var musicbrainzFetchedAt: Int64?

    // MARK: - Init

    // swiftlint:disable function_default_parameter_at_end
    /// Memberwise initialiser.
    public init(
        id: Int64? = nil,
        name: String,
        sortName: String? = nil,
        musicbrainzArtistID: String? = nil,
        disambiguation: String? = nil,
        musicbrainzFetchedAt: Int64? = nil
    ) {
        self.id = id
        self.name = name
        self.sortName = sortName
        self.musicbrainzArtistID = musicbrainzArtistID
        self.disambiguation = disambiguation
        self.musicbrainzFetchedAt = musicbrainzFetchedAt
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
        case musicbrainzFetchedAt = "musicbrainz_fetched_at"
    }
}

// MARK: - Sort-name derivation

/// Fallback sort-name rules used when a file carries no ARTISTSORT tag.
public extension Artist {
    /// Leading articles moved to the end when no ARTISTSORT tag exists.
    ///
    /// English only on purpose: "La Roux" and "Los Lobos" are names, and every
    /// tagger (Picard, iTunes) writes an explicit sort tag when it disagrees.
    static let leadingArticles: [String] = ["the", "a", "an"]

    /// A sort name derived from `name` ("The Beatles" to "Beatles, The"), or
    /// nil when there is no leading article, so the row stays NULL and
    /// ordering falls back to the display name.
    static func derivedSortName(from name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(of: " ") else { return nil }
        let article = trimmed[..<space]
        let rest = trimmed[trimmed.index(after: space)...].trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty, self.leadingArticles.contains(article.lowercased()) else { return nil }
        return "\(rest), \(article)"
    }
}
