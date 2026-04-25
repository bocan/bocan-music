import GRDB

/// Phase 9 migration: per-track and per-album DSP preset assignments.
///
/// These tables let users pin a specific EQ preset (and optional effect values) to an
/// individual track or album. Rows are optional; absence means "use global setting".
///
/// `eq_preset_id` is a plain string that matches `EQPreset.id` (not a FK, since presets
/// live in UserDefaults, not the database — built-ins use `"bocan.*"` IDs, user presets
/// use UUID strings).
enum M010DSPAssignments {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("010_dsp_assignments") { db in
            try db.execute(
                sql: """
                CREATE TABLE track_dsp_assignments (
                    track_id INTEGER PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,
                    eq_preset_id TEXT,
                    bass_boost_db REAL,
                    crossfeed_amount REAL,
                    stereo_width REAL
                )
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE album_dsp_assignments (
                    album_id INTEGER PRIMARY KEY REFERENCES albums(id) ON DELETE CASCADE,
                    eq_preset_id TEXT
                )
                """
            )
        }
    }
}
