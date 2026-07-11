import Foundation
import GRDB

/// Access to the `sync_profile` singleton (Phone Sync, phase 22). Stores the
/// encoded profile as an opaque JSON blob; the `SyncServer` module owns the
/// `SyncProfile` type and its encoding, so this layer stays free of an upward
/// dependency.
public struct SyncProfileRepository: Sendable {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    /// The stored profile JSON, or `nil` if none has been set (the server then
    /// falls back to its default profile).
    public func profileJSON() async throws -> Data? {
        try await self.database.read { db in
            try Data.fetchOne(db, sql: "SELECT profile_json FROM sync_profile WHERE id = 1")
        }
    }

    /// Persists the profile JSON (singleton upsert).
    public func setProfileJSON(_ data: Data) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: """
                INSERT INTO sync_profile (id, profile_json) VALUES (1, ?)
                ON CONFLICT(id) DO UPDATE SET profile_json = excluded.profile_json
                """,
                arguments: [data]
            )
        }
    }
}
