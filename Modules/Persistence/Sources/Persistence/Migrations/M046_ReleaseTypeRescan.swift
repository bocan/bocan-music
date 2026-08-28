import GRDB

/// Migration 046: request the full rescan that populates `albums.release_type`.
///
/// The bridge now reads Picard's RELEASETYPE and the importer rolls it up to
/// the album row (issue #403); existing libraries need one re-read to fill
/// it. No schema change: the column has existed since M001.
enum M046ReleaseTypeRescan {
    static let name = "046_release_type_rescan"

    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration(self.name) { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO pending_maintenance (task, requested_by, requested_at) VALUES (?, ?, strftime('%s','now'))",
                arguments: [PendingMaintenance.Task.fullRescan, self.name]
            )
        }
    }
}
