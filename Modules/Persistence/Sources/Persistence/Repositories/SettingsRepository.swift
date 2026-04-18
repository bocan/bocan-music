import Foundation
import GRDB
import Observability

/// Typed read/write access to the `settings` table.
///
/// Values are `Codable`-encoded to/from `Data` (stored as BLOB).
public struct SettingsRepository: Sendable {
    // MARK: - Properties

    private let database: Database
    private let log = AppLogger.make(.persistence)

    // MARK: - Init

    /// Creates a repository backed by `database`.
    public init(database: Database) {
        self.database = database
    }

    // MARK: - Write

    /// Encodes `value` and writes it under `key`.
    public func set(_ value: some Codable & Sendable, for key: String) async throws {
        let data = try JSONEncoder().encode(value)
        let now = Int64(Date().timeIntervalSince1970)
        let setting = Setting(key: key, value: data, updatedAt: now)
        try await self.database.write { db in
            try setting.save(db)
        }
        self.log.debug("settings.set", ["key": key])
    }

    /// Removes the setting for `key`.
    public func remove(key: String) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: "DELETE FROM settings WHERE key = ?",
                arguments: [key]
            )
        }
        self.log.debug("settings.remove", ["key": key])
    }

    // MARK: - Read

    /// Decodes and returns the setting for `key`, or `nil` if unset.
    public func get<T: Codable & Sendable>(_ type: T.Type, for key: String) async throws -> T? {
        let setting: Setting? = try await self.database.read { db in
            try Setting.fetchOne(db, key: key)
        }
        guard let data = setting?.value else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }
}
