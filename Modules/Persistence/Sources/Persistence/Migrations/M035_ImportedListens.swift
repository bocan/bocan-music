import GRDB

/// Adds `imported_listens` (ADR-076 slice 1): backfilled listening history from a
/// Last.fm export. Kept separate from `play_history` (the local, canonical
/// per-play log) so imports never pollute local counters, stay reversible
/// with one DELETE, and can hold scrobbles for music the library does not
/// contain: `track_id` is nullable, and a re-match pass links rows up as the
/// library grows. The unique index makes re-importing the same export (or a
/// fresh one next year) idempotent.
enum M035ImportedListens {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("035_imported_listens") { db in
            try db.execute(sql: """
                CREATE TABLE imported_listens (
                    id INTEGER PRIMARY KEY,
                    source TEXT NOT NULL DEFAULT 'lastfm',
                    played_at INTEGER NOT NULL,
                    artist TEXT NOT NULL,
                    title TEXT NOT NULL,
                    album TEXT,
                    track_mbid TEXT,
                    track_id INTEGER REFERENCES tracks(id) ON DELETE SET NULL
                )
            """)
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_imported_listens_identity
                ON imported_listens(source, played_at, artist, title)
            """)
            try db.execute(sql: "CREATE INDEX idx_imported_listens_track ON imported_listens(track_id)")
            try db.execute(sql: "CREATE INDEX idx_imported_listens_played_at ON imported_listens(played_at DESC)")
        }
    }
}
