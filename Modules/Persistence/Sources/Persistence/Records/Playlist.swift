import GRDB

/// A playlist row in the `playlists` table.
public struct Playlist: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    // MARK: - Table

    /// The database table name.
    public static let databaseTableName = "playlists"

    // MARK: - Properties

    /// Auto-incremented row identifier; `nil` before first insertion.
    public var id: Int64?

    /// Display name of the playlist.
    public var name: String

    /// Whether this is a smart playlist (criteria-driven).
    public var isSmart: Bool

    /// JSON-encoded smart-playlist criteria (Phase 7 compiler reads this).
    public var smartCriteria: String?

    /// User-defined display order.
    public var sortOrder: Int?

    /// Unix timestamp when the playlist was created.
    public var createdAt: Int64

    /// Unix timestamp of the last update.
    public var updatedAt: Int64

    /// Optional parent playlist for folder hierarchies.
    public var parentID: Int64?

    /// User-set or auto-derived cover art path.
    public var coverArtPath: String?

    // MARK: - Init

    // swiftlint:disable function_default_parameter_at_end
    /// Memberwise initialiser.
    public init(
        id: Int64? = nil,
        name: String,
        isSmart: Bool = false,
        smartCriteria: String? = nil,
        sortOrder: Int? = nil,
        createdAt: Int64,
        updatedAt: Int64,
        parentID: Int64? = nil,
        coverArtPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.isSmart = isSmart
        self.smartCriteria = smartCriteria
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.parentID = parentID
        self.coverArtPath = coverArtPath
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
        case isSmart = "is_smart"
        case smartCriteria = "smart_criteria"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case parentID = "parent_id"
        case coverArtPath = "cover_art_path"
    }
}
