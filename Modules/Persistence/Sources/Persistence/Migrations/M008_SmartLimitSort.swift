import GRDB

/// Phase 7 migration: adds `smart_limit_sort` column to `playlists`.
///
/// `smart_limit_sort` stores a JSON-encoded `LimitSort` value controlling
/// track ordering, limit, and live-update behaviour for smart playlists.
/// It is `NULL` for manual and folder rows.
enum M008SmartLimitSort {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("008_smart_limit_sort") { db in
            try db.execute(
                sql: "ALTER TABLE playlists ADD COLUMN smart_limit_sort TEXT"
            )
            try db.execute(
                sql: "ALTER TABLE playlists ADD COLUMN smart_preset_key TEXT"
            )
        }
    }
}
