import Foundation
import GRDB

/// Phase 2 audit fix: adds `ON DELETE SET NULL` to the soft FK references on
/// `tracks` and `albums`, and propagates artist/album renames into the
/// denormalised `tracks_fts.artist_name` / `tracks_fts.album_title` columns.
///
/// SQLite cannot ALTER an existing FK action, and GRDB's default defensive
/// mode blocks the `writable_schema` shortcut, so this migration uses the
/// canonical 12-step table-swap procedure (see *Making Other Kinds Of Table
/// Schema Changes* in <https://www.sqlite.org/lang_altertable.html>):
///
/// 1. Snapshot the existing CREATE TABLE / index / trigger DDL from
///    `sqlite_master`.
/// 2. Build a new CREATE TABLE statement by string-replacing the FK clauses.
/// 3. Create the new table, copy rows with `INSERT … SELECT *`, drop the
///    original (which removes its indexes and triggers), then rename.
/// 4. Replay the captured indexes and triggers against the new table.
///
/// FK enforcement is disabled by GRDB's migrator for the duration of the
/// migration, so the rewrite cannot trip a constraint check on existing rows.
enum M014ForeignKeyActions {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("014_foreign_key_actions") { db in
            try self.recreateTable(db: db, table: "tracks", replacements: self.tracksReplacements)
            try self.recreateTable(db: db, table: "albums", replacements: self.albumsReplacements)
            try self.replaceArtistFTSTriggers(in: db)
            try self.replaceAlbumFTSTriggers(in: db)
            // Verify the rewritten schema parses cleanly.
            let result = try String.fetchOne(db, sql: "PRAGMA integrity_check") ?? "error"
            guard result == "ok" else {
                throw PersistenceError.integrityCheckFailed(details: result)
            }
        }
    }

    // MARK: - 12-step table swap

    private struct Replacement {
        let old: String
        let new: String
    }

    /// Order matters: the longer, more-specific keys must run first so the
    /// shorter `album_id …` line cannot match the `album_artist_id …`
    /// substring after that line has already been rewritten.
    private static let tracksReplacements: [Replacement] = [
        .init(
            old: "album_artist_id INTEGER REFERENCES artists(id)",
            new: "album_artist_id INTEGER REFERENCES artists(id) ON DELETE SET NULL"
        ),
        .init(
            old: "artist_id INTEGER REFERENCES artists(id)",
            new: "artist_id INTEGER REFERENCES artists(id) ON DELETE SET NULL"
        ),
        .init(
            old: "album_id INTEGER REFERENCES albums(id)",
            new: "album_id INTEGER REFERENCES albums(id) ON DELETE SET NULL"
        ),
        .init(
            old: "cover_art_hash TEXT REFERENCES cover_art(hash)",
            new: "cover_art_hash TEXT REFERENCES cover_art(hash) ON DELETE SET NULL"
        ),
    ]

    private static let albumsReplacements: [Replacement] = [
        .init(
            old: "album_artist_id INTEGER REFERENCES artists(id)",
            new: "album_artist_id INTEGER REFERENCES artists(id) ON DELETE SET NULL"
        ),
        .init(
            old: "cover_art_hash TEXT REFERENCES cover_art(hash)",
            new: "cover_art_hash TEXT REFERENCES cover_art(hash) ON DELETE SET NULL"
        ),
    ]

    private static func recreateTable(
        db: GRDB.Database,
        table: String,
        replacements: [Replacement]
    ) throws {
        let stagingTable = "\(table)_m014_new"
        let newSQL = try buildStagingDDL(
            db: db, table: table, stagingTable: stagingTable, replacements: replacements
        )
        let indexDDL = try fetchDependentDDL(db: db, table: table, type: "index")
        let triggerDDL = try fetchDependentDDL(db: db, table: table, type: "trigger")
        // CREATE staging, copy rows (column lists match because we only
        // edited FK action clauses), drop original (cascades to its indexes
        // + triggers), rename staging in, and replay the captured DDL.
        try db.execute(sql: newSQL)
        try db.execute(sql: "INSERT INTO \(stagingTable) SELECT * FROM \(table)")
        try db.execute(sql: "DROP TABLE \(table)")
        try db.execute(sql: "ALTER TABLE \(stagingTable) RENAME TO \(table)")
        for sql in indexDDL {
            try db.execute(sql: sql)
        }
        for sql in triggerDDL {
            try db.execute(sql: sql)
        }
    }

    private static func buildStagingDDL(
        db: GRDB.Database,
        table: String,
        stagingTable: String,
        replacements: [Replacement]
    ) throws -> String {
        guard
            let originalSQL = try String.fetchOne(
                db,
                sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
                arguments: [table]
            ) else {
            throw PersistenceError.migrationFailed(
                version: 14,
                underlying: NSError(
                    domain: "M014",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Missing CREATE TABLE for \(table)"]
                )
            )
        }
        var newSQL = originalSQL
        for r in replacements {
            newSQL = newSQL.replacingOccurrences(of: r.old, with: r.new)
        }
        // Re-target the CREATE statement at the staging name.  Matches the
        // exact `CREATE TABLE <name>` form M001/M002 produced; if a future
        // migration switched to `CREATE TABLE IF NOT EXISTS <name>` this
        // replacement would silently no-op and the next CREATE would fail.
        newSQL = newSQL.replacingOccurrences(
            of: "CREATE TABLE \(table)",
            with: "CREATE TABLE \(stagingTable)"
        )
        guard newSQL.contains(stagingTable) else {
            throw PersistenceError.migrationFailed(
                version: 14,
                underlying: NSError(
                    domain: "M014",
                    code: 2,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Could not retarget CREATE TABLE for \(table); "
                            + "stored DDL did not match expected `CREATE TABLE \(table)` prefix.",
                    ]
                )
            )
        }
        return newSQL
    }

    /// Snapshots dependent index or trigger DDL so it can be replayed after
    /// the originating table is dropped.  Skips SQLite's auto-created
    /// `sqlite_autoindex_*` entries (rebuilt automatically by the new CREATE).
    private static func fetchDependentDDL(
        db: GRDB.Database,
        table: String,
        type: String
    ) throws -> [String] {
        try String.fetchAll(
            db,
            sql: """
            SELECT sql FROM sqlite_master
             WHERE type = ? AND tbl_name = ?
               AND sql IS NOT NULL
               AND name NOT LIKE 'sqlite_autoindex_%'
            """,
            arguments: [type, table]
        )
    }

    // MARK: - Cross-table FTS triggers

    /// Replaces the M001 `artists_au` trigger with one that also re-emits
    /// every track that references the renamed artist into `tracks_fts`,
    /// so a search for the new artist name resolves immediately.
    private static func replaceArtistFTSTriggers(in db: GRDB.Database) throws {
        try db.execute(sql: "DROP TRIGGER IF EXISTS artists_au")
        try db.execute(
            sql: """
            CREATE TRIGGER artists_au AFTER UPDATE ON artists BEGIN
                DELETE FROM artists_fts WHERE rowid = OLD.id;
                INSERT INTO artists_fts(rowid, name, sort_name)
                VALUES(NEW.id, COALESCE(NEW.name, ''), COALESCE(NEW.sort_name, ''));

                -- Phase-2 audit #3: rebuild denormalised tracks_fts rows for
                -- every track that references this artist.  Without this,
                -- renaming "Boards of Canada" → "BoC" would leave the old
                -- name searchable for the affected tracks until each row
                -- was re-saved.
                DELETE FROM tracks_fts
                WHERE rowid IN (
                    SELECT id FROM tracks WHERE artist_id = NEW.id
                );
                INSERT INTO tracks_fts(rowid, title, composer, genre, artist_name, album_title)
                SELECT
                    t.id,
                    COALESCE(t.title, ''),
                    COALESCE(t.composer, ''),
                    COALESCE(t.genre, ''),
                    COALESCE(NEW.name, ''),
                    COALESCE((SELECT title FROM albums WHERE id = t.album_id), '')
                FROM tracks t WHERE t.artist_id = NEW.id;
            END
            """
        )
    }

    /// Replaces the M001 `albums_au` trigger with one that also re-emits
    /// every track on the renamed album into `tracks_fts`.
    private static func replaceAlbumFTSTriggers(in db: GRDB.Database) throws {
        try db.execute(sql: "DROP TRIGGER IF EXISTS albums_au")
        try db.execute(
            sql: """
            CREATE TRIGGER albums_au AFTER UPDATE ON albums BEGIN
                DELETE FROM albums_fts WHERE rowid = OLD.id;
                INSERT INTO albums_fts(rowid, title)
                VALUES(NEW.id, COALESCE(NEW.title, ''));

                DELETE FROM tracks_fts
                WHERE rowid IN (
                    SELECT id FROM tracks WHERE album_id = NEW.id
                );
                INSERT INTO tracks_fts(rowid, title, composer, genre, artist_name, album_title)
                SELECT
                    t.id,
                    COALESCE(t.title, ''),
                    COALESCE(t.composer, ''),
                    COALESCE(t.genre, ''),
                    COALESCE((SELECT name FROM artists WHERE id = t.artist_id), ''),
                    COALESCE(NEW.title, '')
                FROM tracks t WHERE t.album_id = NEW.id;
            END
            """
        )
    }
}
