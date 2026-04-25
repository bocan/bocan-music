import GRDB

/// Phase 8.5 migration: adds AcoustID fingerprint columns + indexes to `tracks`.
///
/// `musicbrainz_recording_id` was added in M001 but never got an index.
/// That index is added here now that it's used by the scrobbler (Phase 13 handoff).
enum M009AcoustID {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("009_acoustid") { db in
            try db.execute(sql: "ALTER TABLE tracks ADD COLUMN acoustid_fingerprint TEXT")
            try db.execute(sql: "ALTER TABLE tracks ADD COLUMN acoustid_id TEXT")
            try db.execute(
                sql: "CREATE INDEX IF NOT EXISTS idx_tracks_acoustid_id ON tracks(acoustid_id)"
            )
            try db.execute(
                sql: """
                CREATE INDEX IF NOT EXISTS idx_tracks_mb_recording_id \
                ON tracks(musicbrainz_recording_id)
                """
            )
        }
    }
}
