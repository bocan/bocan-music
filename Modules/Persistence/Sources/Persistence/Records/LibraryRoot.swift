import Foundation
import GRDB

/// A root folder that the user has authorised for library scanning.
///
/// Security-scoped bookmarks are stored as raw `Data` so the Library module
/// can reopen the folder after an app restart without a new file-picker.
public struct LibraryRoot: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    // MARK: - Table

    public static let databaseTableName = "library_roots"

    // MARK: - Properties

    /// Auto-incremented row identifier; `nil` before first insertion.
    public var id: Int64?

    /// Normalised absolute path string (UNIQUE constraint).
    public var path: String

    /// Security-scoped bookmark data for sandboxed re-access.
    public var bookmark: Data

    /// Unix timestamp when this root was added.
    public var addedAt: Int64

    /// Set to `true` when the path could not be resolved at last scan attempt.
    public var isInaccessible: Bool

    // MARK: - Init

    // swiftlint:disable function_default_parameter_at_end
    public init(
        id: Int64? = nil,
        path: String,
        bookmark: Data,
        addedAt: Int64,
        isInaccessible: Bool = false
    ) {
        self.id = id
        self.path = path
        self.bookmark = bookmark
        self.addedAt = addedAt
        self.isInaccessible = isInaccessible
    }

    // swiftlint:enable function_default_parameter_at_end

    // MARK: - GRDB

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        self.id = inserted.rowID
    }

    // MARK: - CodingKeys

    private enum CodingKeys: String, CodingKey {
        case id
        case path
        case bookmark
        case addedAt = "added_at"
        case isInaccessible = "is_inaccessible"
    }
}
