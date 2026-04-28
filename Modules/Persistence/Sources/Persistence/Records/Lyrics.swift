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

    /// Where the lyrics came from: `"embedded"`, `"lrc-file"`, `"user"`, or `"lrclib"`.
    public var source: String?

    /// Per-track display offset in milliseconds applied on top of any `[offset:]` tag.
    ///
    /// Positive values mean the lyrics run ahead of the audio (subtract from timestamps).
    public var offsetMS: Int

    // MARK: - Init

    public init(
        trackID: Int64,
        lyricsText: String? = nil,
        isSynced: Bool = false,
        source: String? = nil,
        offsetMS: Int = 0
    ) {
        self.trackID = trackID
        self.lyricsText = lyricsText
        self.isSynced = isSynced
        self.source = source
        self.offsetMS = offsetMS
    }

    // MARK: - CodingKeys

    private enum CodingKeys: String, CodingKey {
        case trackID = "track_id"
        case lyricsText = "lyrics_text"
        case isSynced = "is_synced"
        case source
        case offsetMS = "offset_ms"
    }
}
