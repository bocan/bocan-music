import Foundation
import GRDB

/// Migration 004: adds `excluded_from_shuffle` flag to the `albums` table.
///
/// When `true`, all tracks from this album are treated as excluded from shuffle
/// (the same semantics as `Track.excluded_from_shuffle`).
enum M004AlbumExcludedFromShuffle {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("004_album_excluded_from_shuffle") { db in
            try db.execute(
                sql: "ALTER TABLE albums ADD COLUMN excluded_from_shuffle INTEGER NOT NULL DEFAULT 0"
            )
        }
    }
}
