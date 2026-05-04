import GRDB

/// Migration 019: prevents the same track appearing twice in one playlist.
///
/// `playlist_tracks` has `PRIMARY KEY (playlist_id, position)` which allows
/// a track to be added at multiple positions.  The AppKit diffable data source
/// uses `Int64` track IDs as unique item identifiers, so duplicate entries
/// crash with "Duplicate values for key" when the table is rendered.
///
/// This migration:
/// 1. Removes every duplicate `(playlist_id, track_id)` pair, keeping the
///    lowest-position occurrence.
/// 2. Adds a `UNIQUE (playlist_id, track_id)` index so future inserts that
///    would create a duplicate are rejected at the database level.
enum M019PlaylistTrackUnique {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("019_playlist_track_unique") { db in
            // 1. Delete all but the earliest occurrence of each
            //    (playlist_id, track_id) pair.
            try db.execute(sql: """
            DELETE FROM playlist_tracks
            WHERE rowid NOT IN (
                SELECT MIN(rowid)
                FROM playlist_tracks
                GROUP BY playlist_id, track_id
            )
            """)

            // 2. Enforce uniqueness going forward.
            try db.execute(sql: """
            CREATE UNIQUE INDEX IF NOT EXISTS
            idx_pt_unique_membership ON playlist_tracks(playlist_id, track_id)
            """)
        }
    }
}
