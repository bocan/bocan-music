import Foundation
import GRDB

/// Phase 6 migration: adds `kind` and `accent_color` columns to `playlists`.
///
/// `kind` supersedes the legacy `is_smart` flag: it can be `'manual'`,
/// `'smart'`, or `'folder'`. Existing rows are back-filled:
///   - `is_smart = 1` → `'smart'`
///   - `is_smart = 0` → `'manual'`
///
/// `is_smart` stays in the schema for backward compatibility; the
/// Swift layer treats `kind` as canonical. Folders are a new concept
/// introduced here.
///
/// `accent_color` is an optional hex string (`"#RRGGBB"`) surfaced by the
/// sidebar row dot and the detail header tint.
enum M007PlaylistKindAccent {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("007_playlist_kind_accent") { db in
            try db.execute(
                sql: "ALTER TABLE playlists ADD COLUMN kind TEXT NOT NULL DEFAULT 'manual'"
            )
            try db.execute(
                sql: "ALTER TABLE playlists ADD COLUMN accent_color TEXT"
            )
            try db.execute(
                sql: """
                UPDATE playlists
                   SET kind = CASE WHEN is_smart = 1 THEN 'smart' ELSE 'manual' END
                """
            )
        }
    }
}
