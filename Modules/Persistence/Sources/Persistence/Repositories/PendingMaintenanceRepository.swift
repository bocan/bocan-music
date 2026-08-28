import Foundation
import GRDB
import Observability

/// Reads and clears the one-time tasks migrations leave in `pending_maintenance` (#425).
public struct PendingMaintenanceRepository: Sendable {
    private let database: Database
    private let log = AppLogger.make(.persistence)

    /// Creates a repository backed by `database`.
    public init(database: Database) {
        self.database = database
    }

    /// Every outstanding request for `task`, oldest first.
    public func requests(task: String) async throws -> [PendingMaintenance] {
        try await self.database.read { db in
            try PendingMaintenance
                .filter(Column("task") == task)
                .order(Column("requested_at"), Column("requested_by"))
                .fetchAll(db)
        }
    }

    /// Whether at least one request for `task` is outstanding.
    public func hasRequest(task: String) async throws -> Bool {
        try await !self.requests(task: task).isEmpty
    }

    /// Records a request; a duplicate (same task and requester) is ignored.
    public func request(task: String, requestedBy: String, now: Date = Date()) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO pending_maintenance (task, requested_by, requested_at) VALUES (?, ?, ?)",
                arguments: [task, requestedBy, Int64(now.timeIntervalSince1970)]
            )
        }
        self.log.debug("maintenance.requested", ["task": task, "by": requestedBy])
    }

    /// Clears every request for `task` once it has completed.
    public func clear(task: String) async throws {
        let removed: Int = try await self.database.write { db in
            try db.execute(sql: "DELETE FROM pending_maintenance WHERE task = ?", arguments: [task])
            return db.changesCount
        }
        self.log.debug("maintenance.cleared", ["task": task, "requests": removed])
    }
}
