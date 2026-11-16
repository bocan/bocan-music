import GRDB

/// ADR-097 slice 6: Jellyfin play reports through the scrobble queue.
///
/// Adds `jellyfin_server_id` and `jellyfin_item_id` to `scrobble_queue`, the
/// twins of M021's Subsonic pair. A Jellyfin play has no `tracks` row, so
/// `track_id` stays NULL and the `payload_*` columns from M021 carry its title,
/// artist, album and length, as they do for a Subsonic play.
///
/// The unique index on `(jellyfin_server_id, jellyfin_item_id, played_at)`
/// makes the enqueue idempotent (`INSERT OR IGNORE`), as M021's index does for
/// Subsonic. SQLite treats NULLs as distinct, so local and Subsonic rows, which
/// leave both columns NULL, never collide on it.
enum M056JellyfinScrobble {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("056_jellyfin_scrobble") { db in
            try db.execute(sql: """
            ALTER TABLE scrobble_queue ADD COLUMN jellyfin_server_id TEXT
            """)
            try db.execute(sql: """
            ALTER TABLE scrobble_queue ADD COLUMN jellyfin_item_id TEXT
            """)
            try db.execute(sql: """
            CREATE UNIQUE INDEX IF NOT EXISTS uniq_scrobble_queue_jellyfin_playedat
              ON scrobble_queue(jellyfin_server_id, jellyfin_item_id, played_at)
            """)
        }
    }
}
