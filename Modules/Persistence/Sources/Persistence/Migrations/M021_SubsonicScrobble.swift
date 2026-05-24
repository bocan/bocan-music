import GRDB

/// Phase 19 step 15 — Subsonic scrobble write-through.
///
/// Adds optional `subsonic_server_id` / `subsonic_song_id` columns to
/// `scrobble_queue` so plays originating from a Subsonic source can flow
/// through the existing scrobble dispatch pipeline without a local
/// `tracks.id` to reference. Local plays continue to use `track_id`; one of
/// the two identities is always present.
///
/// Adds an `artist`/`title`/`album`/`album_artist`/`duration` payload to the
/// queue row itself so the worker can build a `PlayEvent` for Subsonic plays
/// without joining the `tracks` table (Subsonic songs are never inserted
/// into `tracks`).
enum M021SubsonicScrobble {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("021_subsonic_scrobble") { db in
            try db.execute(sql: """
            ALTER TABLE scrobble_queue ADD COLUMN subsonic_server_id TEXT
            """)
            try db.execute(sql: """
            ALTER TABLE scrobble_queue ADD COLUMN subsonic_song_id TEXT
            """)
            try db.execute(sql: """
            ALTER TABLE scrobble_queue ADD COLUMN payload_title TEXT
            """)
            try db.execute(sql: """
            ALTER TABLE scrobble_queue ADD COLUMN payload_artist TEXT
            """)
            try db.execute(sql: """
            ALTER TABLE scrobble_queue ADD COLUMN payload_album TEXT
            """)
            try db.execute(sql: """
            ALTER TABLE scrobble_queue ADD COLUMN payload_album_artist TEXT
            """)
            try db.execute(sql: """
            ALTER TABLE scrobble_queue ADD COLUMN payload_duration REAL
            """)
            try db.execute(sql: """
            CREATE UNIQUE INDEX IF NOT EXISTS uniq_scrobble_queue_subsonic_playedat
              ON scrobble_queue(subsonic_server_id, subsonic_song_id, played_at)
            """)
        }
    }
}
