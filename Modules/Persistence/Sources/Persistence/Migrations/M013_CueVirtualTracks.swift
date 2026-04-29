import GRDB

/// Phase 14 migration: adds offset columns to support CUE-sheet virtual tracks.
///
/// `start_offset_ms` and `end_offset_ms` are non-negative integers measured in
/// milliseconds from the start of the source file. When both are NULL the
/// track is a normal whole-file track (the historical behaviour). When set,
/// the audio decoder must clamp playback to `[start_offset_ms, end_offset_ms)`.
///
/// `source_file_url` is set when several rows share the same physical file
/// (typical of an album rip with a sidecar CUE) and is used by the importer
/// to deduplicate virtual tracks against an existing single-file row.
enum M013CueVirtualTracks {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("013_cue_virtual_tracks") { db in
            try db.alter(table: "tracks") { table in
                table.add(column: "start_offset_ms", .integer)
                table.add(column: "end_offset_ms", .integer)
                table.add(column: "source_file_url", .text)
            }
            try db.execute(
                sql: "CREATE INDEX IF NOT EXISTS idx_tracks_source_file_url ON tracks(source_file_url)"
            )
        }
    }
}
