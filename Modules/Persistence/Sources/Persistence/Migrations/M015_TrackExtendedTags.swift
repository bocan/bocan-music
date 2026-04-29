import Foundation
import GRDB

/// Migration 015: adds `extended_tags` column to the `tracks` table.
///
/// Stores the full TagLib `PropertyMap` for a file as a JSON object with
/// string-array values, e.g. `{"ARTIST":["Run DMC","Aerosmith"]}`. Preserves
/// multi-valued tags (Vorbis comments and ID3v2.4 frames can have multiple
/// values per key) that the flat `artist`/`genre`/etc. columns cannot
/// represent. The primary value is still mirrored into `tracks.artist` (joined
/// with `; ` when there are multiple) for sorting and display.
///
/// Nullable so existing rows remain valid; `TrackImporter` will populate it
/// on the next rescan.
enum M015TrackExtendedTags {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("015_track_extended_tags") { db in
            try db.execute(
                sql: "ALTER TABLE tracks ADD COLUMN extended_tags TEXT"
            )
        }
    }
}
