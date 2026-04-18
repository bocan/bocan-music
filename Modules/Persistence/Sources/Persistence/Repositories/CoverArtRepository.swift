import GRDB
import Observability

/// Hash-deduplicating read/write access to the `cover_art` table.
///
/// All writes use `save()` (insert-or-ignore semantics keyed on `hash`).
/// Callers are responsible for reference-counting before deleting.
public struct CoverArtRepository: Sendable {
    // MARK: - Properties

    private let database: Database
    private let log = AppLogger.make(.persistence)

    // MARK: - Init

    /// Creates a repository backed by `database`.
    public init(database: Database) {
        self.database = database
    }

    // MARK: - Write

    /// Saves `art` by hash.  If an identical hash already exists, returns the stored path.
    ///
    /// Returns the canonical path that callers should reference.
    @discardableResult
    public func save(_ art: CoverArt) async throws -> String {
        try await self.database.write { db in
            if let existing = try CoverArt.fetchOne(db, key: art.hash) {
                return existing.path
            }
            try art.save(db)
            return art.path
        }
    }

    /// Deletes the cover-art row with `hash`.
    ///
    /// **Callers must check reference counts** before calling this.
    public func delete(hash: String) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: "DELETE FROM cover_art WHERE hash = ?",
                arguments: [hash]
            )
        }
        self.log.debug("cover_art.delete", ["hash": hash])
    }

    // MARK: - Read

    /// Fetches the cover-art row for `hash`, or `nil` if absent.
    public func fetch(hash: String) async throws -> CoverArt? {
        try await self.database.read { db in
            try CoverArt.fetchOne(db, key: hash)
        }
    }
}
