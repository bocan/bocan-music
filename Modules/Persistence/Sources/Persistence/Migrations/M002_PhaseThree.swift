import Foundation
import GRDB

/// Phase 3 migration: adds `user_edited` flag to tracks, creates `library_roots` table.
///
/// `library_roots` records the folders the user has authorised for scanning,
/// together with a security-scoped bookmark so the Library module can re-open
/// them after an app restart without showing another Open panel.
enum M002PhaseThree {
    // MARK: - Registration

    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("002_phase_three") { db in
            // Add user-edited flag; preserves user tag edits across rescans.
            try db.execute(
                sql: "ALTER TABLE tracks ADD COLUMN user_edited BOOLEAN NOT NULL DEFAULT 0"
            )

            // Add MusicBrainz release identifiers absent from M001.
            try db.execute(
                sql: "ALTER TABLE tracks ADD COLUMN musicbrainz_album_artist_id TEXT"
            )
            try db.execute(
                sql: "ALTER TABLE tracks ADD COLUMN musicbrainz_release_id TEXT"
            )
            try db.execute(
                sql: "ALTER TABLE tracks ADD COLUMN musicbrainz_release_group_id TEXT"
            )

            // Disc/track total columns for completeness.
            try db.execute(
                sql: "ALTER TABLE tracks ADD COLUMN track_total INTEGER"
            )
            try db.execute(
                sql: "ALTER TABLE tracks ADD COLUMN disc_total INTEGER"
            )

            // Root folders that the user has authorised for library scanning.
            try db.execute(
                sql: """
                CREATE TABLE library_roots (
                    id INTEGER PRIMARY KEY,
                    path TEXT NOT NULL UNIQUE,
                    bookmark BLOB NOT NULL,
                    added_at INTEGER NOT NULL,
                    is_inaccessible BOOLEAN NOT NULL DEFAULT 0
                )
                """
            )
        }
    }
}
