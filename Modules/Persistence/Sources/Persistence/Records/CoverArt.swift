import GRDB

/// A deduplicated cover-art entry in the `cover_art` table.
///
/// Stored once by SHA-256 hash; `albums.cover_art_hash` and
/// `tracks.cover_art_hash` reference this table.
/// Deletion must be reference-counted in `CoverArtRepository`.
public struct CoverArt: Codable, FetchableRecord, PersistableRecord, Sendable {
    // MARK: - Table

    /// The database table name.
    public static let databaseTableName = "cover_art"

    // MARK: - Properties

    /// SHA-256 hash of the image bytes (primary key).
    public var hash: String

    /// Absolute path to the cached image file.
    public var path: String

    /// Image width in pixels.
    public var width: Int?

    /// Image height in pixels.
    public var height: Int?

    /// Image format: `"jpeg"`, `"png"`, or `"webp"`.
    public var format: String?

    /// File size in bytes.
    public var byteSize: Int?

    /// Where the image originated: `"embedded"`, `"sidecar"`, `"musicbrainz"`, or `"user"`.
    public var source: String?

    // MARK: - Init

    /// Memberwise initialiser.
    public init(
        hash: String,
        path: String,
        width: Int? = nil,
        height: Int? = nil,
        format: String? = nil,
        byteSize: Int? = nil,
        source: String? = nil
    ) {
        self.hash = hash
        self.path = path
        self.width = width
        self.height = height
        self.format = format
        self.byteSize = byteSize
        self.source = source
    }

    // MARK: - CodingKeys

    private enum CodingKeys: String, CodingKey {
        case hash
        case path
        case width
        case height
        case format
        case byteSize = "byte_size"
        case source
    }
}
