import GRDB

/// Migration 047: one more rescan for `albums.release_type` (issue #403).
///
/// M046's rescan took the first RELEASETYPE value; some taggers prepend junk
/// (`["ELEAS", "album", "compilation"]`), which landed as the type on 79
/// albums of a real library. The reader now prefers a known MusicBrainz type
/// anywhere in the list; request a re-read so those rows heal.
enum M047ReleaseTypeJunkRescan {
    static let name = "047_release_type_junk_rescan"

    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration(self.name) { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO pending_maintenance (task, requested_by, requested_at) VALUES (?, ?, strftime('%s','now'))",
                arguments: [PendingMaintenance.Task.fullRescan, self.name]
            )
        }
    }
}
