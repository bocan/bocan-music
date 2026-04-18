import GRDB
import Observability

/// Enqueues and drains the `scrobble_queue` table.
public struct ScrobbleRepository: Sendable {
    // MARK: - Properties

    private let database: Database
    private let log = AppLogger.make(.persistence)

    // MARK: - Init

    /// Creates a repository backed by `database`.
    public init(database: Database) {
        self.database = database
    }

    // MARK: - Write

    /// Enqueues a new scrobble and returns its `id`.
    @discardableResult
    public func enqueue(_ item: ScrobbleQueueItem) async throws -> Int64 {
        let id: Int64 = try await self.database.write { db in
            var mutable = item
            try mutable.insert(db)
            guard let rowID = mutable.id else {
                throw PersistenceError.notFound(entity: "ScrobbleQueueItem", id: -1)
            }
            return rowID
        }
        self.log.debug("scrobble.enqueue", ["id": id])
        return id
    }

    /// Marks the item with `id` as submitted.
    public func markSubmitted(id: Int64) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: "UPDATE scrobble_queue SET submitted = 1 WHERE id = ?",
                arguments: [id]
            )
        }
        self.log.debug("scrobble.submitted", ["id": id])
    }

    /// Increments the `submission_attempts` counter for `id`.
    public func incrementAttempts(id: Int64) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: "UPDATE scrobble_queue SET submission_attempts = submission_attempts + 1 WHERE id = ?",
                arguments: [id]
            )
        }
    }

    // MARK: - Read

    /// Fetches all unsubmitted items, oldest first.
    public func fetchPending() async throws -> [ScrobbleQueueItem] {
        try await self.database.read { db in
            try ScrobbleQueueItem
                .filter(Column("submitted") == false)
                .order(Column("played_at"))
                .fetchAll(db)
        }
    }

    /// Returns the count of unsubmitted items.
    public func pendingCount() async throws -> Int {
        try await self.database.read { db in
            try ScrobbleQueueItem.filter(Column("submitted") == false).fetchCount(db)
        }
    }
}
