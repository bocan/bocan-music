import Foundation
import GRDB

/// Migration 016: adds `smart_last_snapshot_at` column to the `playlists` table.
///
/// Tracks when a smart playlist last materialised its result set, so the UI
/// can show a staleness indicator and schedule background refreshes without
/// re-running the query on every view appearance.
///
/// Nullable so existing rows remain valid; the column is populated on the
/// next smart-playlist evaluation.
enum M016SmartLastSnapshotAt {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("016_smart_last_snapshot_at") { db in
            try db.alter(table: "playlists") { table in
                table.add(column: "smart_last_snapshot_at", .integer)
            }
        }
    }
}
