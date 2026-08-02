import GRDB

/// Adds the transcode-detection verdict columns to `tracks` (phase 24-2):
/// `provenance_suspected` (bool), `provenance_confidence` (0...1),
/// `provenance_shelf_hz` (the detected spectral-shelf edge), and
/// `provenance_analysed_at` (epoch seconds). Columns rather than a side
/// table: verdicts are 1:1 with tracks and the Library Summary queries want
/// them cheap. All NULL until the "Analyse Provenance" batch job (24-3)
/// writes a verdict; the scanner nulls them again when `file_mtime` changes
/// so a replaced file is never judged by its predecessor's spectrum.
enum M034Provenance {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("034_provenance") { db in
            try db.execute(sql: "ALTER TABLE tracks ADD COLUMN provenance_suspected BOOLEAN")
            try db.execute(sql: "ALTER TABLE tracks ADD COLUMN provenance_confidence DOUBLE")
            try db.execute(sql: "ALTER TABLE tracks ADD COLUMN provenance_shelf_hz INTEGER")
            try db.execute(sql: "ALTER TABLE tracks ADD COLUMN provenance_analysed_at INTEGER")
        }
    }
}
