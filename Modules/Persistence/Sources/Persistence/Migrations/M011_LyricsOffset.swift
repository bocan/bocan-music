import GRDB

/// Adds `offset_ms` (integer, default 0) to the `lyrics` table.
///
/// The offset follows LRC convention: a positive value means the lyrics file's timestamps
/// run ahead of the audio by that many milliseconds.
enum M011LyricsOffset {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("011_lyrics_offset") { db in
            try db.alter(table: "lyrics") { table in
                table.add(column: "offset_ms", .integer).defaults(to: 0)
            }
        }
    }
}
