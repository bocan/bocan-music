import GRDB

/// CUE sheets as in-track markers (ADR-087): the chapters model replaces the
/// virtual-track split. `track_markers` holds cue points per track; the
/// cleanup deletes the retired `?cue=N` virtual rows (their playlist
/// memberships cascade with them).
enum M038TrackMarkers {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("038_track_markers") { db in
            try db.execute(sql: """
            CREATE TABLE track_markers (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                track_id INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
                position_ms INTEGER NOT NULL,
                title TEXT,
                performer TEXT
            )
            """)
            try db.execute(sql: "CREATE INDEX idx_track_markers_track ON track_markers(track_id)")
            // Retire the virtual-track model: every `?cue=N` row goes. The
            // `?` and `=` are literal characters in LIKE, so no escaping.
            try db.execute(sql: "DELETE FROM tracks WHERE file_url LIKE '%?cue=%'")
        }
    }
}
