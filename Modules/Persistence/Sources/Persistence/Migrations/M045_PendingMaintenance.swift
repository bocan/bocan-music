import GRDB

/// Migration 045: one-time maintenance requests (issue #425).
///
/// A migration that changes what the importer extracts cannot take effect
/// until every file is re-read, and the launch scan skips unchanged files by
/// design. `pending_maintenance` lets such a migration leave a request inside
/// its own transaction; the next launch runs the task silently and clears the
/// rows when it completes (a crash mid-task leaves them, so it runs again).
///
/// This migration requests a full rescan for itself: libraries upgraded past
/// it pick up #399 (artist MBIDs), #400 (sort names), #404 (n/N totals),
/// #405 (bit depth) and #417 (cover-art metadata) without user action.
enum M045PendingMaintenance {
    static let name = "045_pending_maintenance"

    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration(self.name) { db in
            try db.execute(sql: """
            CREATE TABLE pending_maintenance (
                task         TEXT NOT NULL,
                requested_by TEXT NOT NULL,
                requested_at INTEGER NOT NULL,
                PRIMARY KEY (task, requested_by)
            )
            """)
            try db.execute(
                sql: "INSERT INTO pending_maintenance (task, requested_by, requested_at) VALUES (?, ?, strftime('%s','now'))",
                arguments: [PendingMaintenance.Task.fullRescan, self.name]
            )
        }
    }
}
