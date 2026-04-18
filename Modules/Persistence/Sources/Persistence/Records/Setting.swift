import Foundation
import GRDB

/// A key/value application setting stored in the `settings` table.
///
/// Values are stored as `BLOB` (raw `Data`) so any `Codable` type can be persisted.
/// Strings should be stored as UTF-8–encoded `Data`.
public struct Setting: Codable, FetchableRecord, PersistableRecord, Sendable {
    // MARK: - Table

    /// The database table name.
    public static let databaseTableName = "settings"

    // MARK: - Properties

    /// Unique string key identifying the setting.
    public var key: String

    /// Raw BLOB value; decoded by the caller.
    public var value: Data

    /// Unix timestamp of the last write.
    public var updatedAt: Int64

    // MARK: - Init

    /// Memberwise initialiser.
    public init(key: String, value: Data, updatedAt: Int64) {
        self.key = key
        self.value = value
        self.updatedAt = updatedAt
    }

    // MARK: - CodingKeys

    private enum CodingKeys: String, CodingKey {
        case key
        case value
        case updatedAt = "updated_at"
    }
}
