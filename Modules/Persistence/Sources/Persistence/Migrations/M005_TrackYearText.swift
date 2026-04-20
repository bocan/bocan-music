import Foundation
import GRDB

/// Migration 005: adds `year_text` column to the `tracks` table.
///
/// Stores the raw year/date string from the file tag to preserve values
/// TagLib's numeric `year()` strips (ranges like "1979-1980", ISO dates,
/// partial dates like "1974-05").
enum M005TrackYearText {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("005_track_year_text") { db in
            try db.execute(
                sql: "ALTER TABLE tracks ADD COLUMN year_text TEXT"
            )
        }
    }
}
