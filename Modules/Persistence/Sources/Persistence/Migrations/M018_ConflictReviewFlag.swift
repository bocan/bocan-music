import GRDB

/// Migration 018: adds `needs_conflict_review` flag to the `tracks` table.
///
/// When the library scanner detects that a file on disk was modified after the
/// user last edited its tags (Phase 3 `ConflictResolver`), it sets this flag
/// instead of overwriting user edits. The Tag Editor reads it on open and
/// shows a resolution banner ("Keep My Edits / Take Disk Version / Show Diff").
/// Once the user resolves the conflict the flag is cleared.
enum M018ConflictReviewFlag {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("018_conflict_review_flag") { db in
            try db.execute(
                sql: "ALTER TABLE tracks ADD COLUMN needs_conflict_review BOOLEAN NOT NULL DEFAULT 0"
            )
        }
    }
}
