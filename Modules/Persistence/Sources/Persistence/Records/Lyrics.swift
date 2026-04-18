import GRDB

/// Lyrics for a single track (one-to-one with `tracks`).
///
/// The primary key is `track_id`.  Deleting the parent track cascades
/// to this row automatically.
public struct Lyrics: Codable, FetchableRecord, PersistableRecord, Sendable {
    // MARK: - Table

    /// The database table name.
    public static let databaseTableName = "lyrics"

    // MARK: - Properties

    /// The owning track identifier (primary key).
    public var trackID: Int64

    /// Plain or LRC-formatted lyrics text.
    public var lyricsText: String?

    /// Whether `lyricsText` contains LRC time-code markers.
    public var isSynced: Bool

    /// Where the lyrics came from: `"embedded"`, `"lrc-file"`, or `"fetched"`.
    public var source: String?

    // MARK: - Init

    /// Memberwise initialiser.
    public init(
        trackID: Int64,
        lyricsText: String? = nil,
        isSynced: Bool = false,
        source: String? = nil
    ) {
        self.trackID = trackID
        self.lyricsText = lyricsText
        self.isSynced = isSynced
        self.source = source
    }

    // MARK: - CodingKeys

    private enum CodingKeys: String, CodingKey {
        case trackID = "track_id"
        case lyricsText = "lyrics_text"
        case isSynced = "is_synced"
        case source
    }
}
