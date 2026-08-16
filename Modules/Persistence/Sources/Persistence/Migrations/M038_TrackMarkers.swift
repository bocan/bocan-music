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
            //
            // GRDB runs migrations with foreign keys DISABLED and validates
            // with a full foreign_key_check afterwards, so ON DELETE CASCADE
            // never fires here — every dependent row must go explicitly
            // (including scrobble_submissions, transitively behind
            // scrobble_queue), or the post-migration check fails and the
            // database refuses to open. Found the hard way on a real library
            // whose virtual tracks had scrobble history.
            let virtual = "SELECT id FROM tracks WHERE file_url LIKE '%?cue=%'"
            try db.execute(sql: """
            DELETE FROM scrobble_submissions WHERE queue_id IN
                (SELECT id FROM scrobble_queue WHERE track_id IN (\(virtual)))
            """)
            for table in ["playlist_tracks", "lyrics", "scrobble_queue", "play_history", "track_dsp_assignments"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE track_id IN (\(virtual))")
            }
            try db.execute(sql: "UPDATE imported_listens SET track_id = NULL WHERE track_id IN (\(virtual))")
            try db.execute(sql: "DELETE FROM tracks WHERE file_url LIKE '%?cue=%'")
        }
    }
}
