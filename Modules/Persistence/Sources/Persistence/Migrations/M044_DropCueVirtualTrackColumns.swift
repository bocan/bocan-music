import GRDB

/// Migration 044: drop the CUE virtual-track columns (issue #406).
///
/// `start_offset_ms`, `end_offset_ms` and `source_file_url` were added by M013
/// for the virtual-track CUE design that ADR-087 superseded with in-track
/// markers; M038 deleted the last virtual rows. No code has written these
/// columns since, so they are removed along with their index. The engine's
/// segment primitive (`AudioEngine.setSegment`) stays per ADR-087.
enum M044DropCueVirtualTrackColumns {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("044_drop_cue_virtual_track_columns") { db in
            try db.execute(sql: "DROP INDEX IF EXISTS idx_tracks_source_file_url")
            try db.alter(table: "tracks") { table in
                table.drop(column: "start_offset_ms")
                table.drop(column: "end_offset_ms")
                table.drop(column: "source_file_url")
            }
        }
    }
}
