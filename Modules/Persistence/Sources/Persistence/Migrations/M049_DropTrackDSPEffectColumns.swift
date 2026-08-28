import GRDB

/// Migration 049: drop the per-track effect columns M010 added but nothing
/// ever wrote or read (issue #418).
///
/// `track_dsp_assignments` was sketched with `bass_boost_db`,
/// `crossfeed_amount` and `stereo_width` alongside `eq_preset_id`, but the
/// shipped feature (ADR-013) is per-track and per-album EQ presets only;
/// bass boost, crossfeed and stereo width are global toggles and
/// `DSPAssignmentRepository` handles `eq_preset_id` alone. `album_dsp_assignments`
/// was already scoped that narrowly. Drop the three so the schema matches.
enum M049DropTrackDSPEffectColumns {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("049_drop_track_dsp_effect_columns") { db in
            try db.alter(table: "track_dsp_assignments") { table in
                table.drop(column: "bass_boost_db")
                table.drop(column: "crossfeed_amount")
                table.drop(column: "stereo_width")
            }
        }
    }
}
