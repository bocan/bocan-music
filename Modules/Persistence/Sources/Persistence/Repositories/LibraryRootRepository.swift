import Foundation
import GRDB
import Observability

/// Read/write access to the `library_roots` table.
public struct LibraryRootRepository: Sendable {
    // MARK: - Properties

    private let database: Database
    private let log = AppLogger.make(.persistence)

    // MARK: - Init

    public init(database: Database) {
        self.database = database
    }

    // MARK: - Write

    /// Inserts `root`, or replaces an existing row with the same `path`.
    @discardableResult
    public func upsert(_ root: LibraryRoot) async throws -> LibraryRoot {
        try await self.database.write { db in
            var mutable = root
            try mutable.save(db)
            return mutable
        }
    }

    /// Marks a root as inaccessible (path still retained for diagnostics).
    public func markInaccessible(id: Int64, _ flag: Bool) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: "UPDATE library_roots SET is_inaccessible = ? WHERE id = ?",
                arguments: [flag, id]
            )
        }
    }

    /// Removes the library root with `id`.
    public func delete(id: Int64) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: "DELETE FROM library_roots WHERE id = ?",
                arguments: [id]
            )
        }
        self.log.debug("library_root.delete", ["id": id])
    }

    // MARK: - Read

    /// Returns all registered library roots.
    public func fetchAll() async throws -> [LibraryRoot] {
        try await self.database.read { db in
            try LibraryRoot.fetchAll(db)
        }
    }

    /// Returns the root with `id`, or throws if not found.
    public func fetch(id: Int64) async throws -> LibraryRoot {
        try await self.database.read { db in
            guard let root = try LibraryRoot.fetchOne(db, key: id) else {
                throw PersistenceError.notFound(entity: "library_roots", id: id)
            }
            return root
        }
    }
}
