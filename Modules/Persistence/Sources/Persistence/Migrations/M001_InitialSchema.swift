import Foundation
import GRDB

/// The initial database schema: all tables, FTS virtual tables, triggers, and indexes.
///
/// This migration is **append-only** once merged to `main`.
/// If corrections are needed post-merge, add `M002`.
enum M001InitialSchema {
    // MARK: - Registration

    /// Registers the migration with `migrator`.
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("001_initial_schema") { db in
            try self.createCoreTables(in: db)
            try self.createCoverArtTable(in: db)
            try self.createPlayHistoryTable(in: db)
            try self.createSettingsTables(in: db)
            try self.createFTSTables(in: db)
            try self.createTrackFTSTriggers(in: db)
            try self.createArtistFTSTriggers(in: db)
            try self.createAlbumFTSTriggers(in: db)
            try self.createIndexes(in: db)
            try self.seedMetadata(in: db)
        }
    }

    // MARK: - Core tables

    private static func createCoreTables(in db: GRDB.Database) throws {
        try self.createArtistsTable(in: db)
        try self.createAlbumsTable(in: db)
        try self.createTracksTable(in: db)
        try self.createPlaylistsTable(in: db)
        try self.createPlaylistTracksTable(in: db)
        try self.createLyricsTable(in: db)
        try self.createScrobbleQueueTable(in: db)
    }

    private static func createArtistsTable(in db: GRDB.Database) throws {
        try db.execute(
            sql: """
            CREATE TABLE artists (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                sort_name TEXT,
                musicbrainz_artist_id TEXT,
                disambiguation TEXT,
                UNIQUE(name)
            )
            """
        )
    }

    private static func createAlbumsTable(in db: GRDB.Database) throws {
        try db.execute(
            sql: """
            CREATE TABLE albums (
                id INTEGER PRIMARY KEY,
                title TEXT NOT NULL,
                album_artist_id INTEGER REFERENCES artists(id),
                year INTEGER,
                musicbrainz_release_id TEXT,
                musicbrainz_release_group_id TEXT,
                cover_art_hash TEXT REFERENCES cover_art(hash),
                release_type TEXT,
                total_tracks INTEGER,
                total_discs INTEGER,
                cover_art_path TEXT,
                UNIQUE(title, album_artist_id)
            )
            """
        )
    }

    // swiftlint:disable function_body_length
    private static func createTracksTable(in db: GRDB.Database) throws {
        try db.execute(
            sql: """
            CREATE TABLE tracks (
                id INTEGER PRIMARY KEY,
                file_url TEXT NOT NULL UNIQUE,
                file_bookmark BLOB,
                file_size INTEGER NOT NULL DEFAULT 0,
                file_mtime INTEGER NOT NULL DEFAULT 0,
                file_format TEXT NOT NULL DEFAULT '',
                duration REAL NOT NULL DEFAULT 0,
                sample_rate INTEGER,
                bit_depth INTEGER,
                bitrate INTEGER,
                channel_count INTEGER,
                is_lossless BOOLEAN,
                title TEXT,
                artist_id INTEGER REFERENCES artists(id),
                album_artist_id INTEGER REFERENCES artists(id),
                album_id INTEGER REFERENCES albums(id),
                track_number INTEGER,
                disc_number INTEGER,
                year INTEGER,
                genre TEXT,
                composer TEXT,
                bpm REAL,
                key TEXT,
                isrc TEXT,
                musicbrainz_track_id TEXT,
                musicbrainz_recording_id TEXT,
                replaygain_track_gain REAL,
                replaygain_track_peak REAL,
                replaygain_album_gain REAL,
                replaygain_album_peak REAL,
                play_count INTEGER DEFAULT 0,
                skip_count INTEGER DEFAULT 0,
                last_played_at INTEGER,
                rating INTEGER DEFAULT 0,
                loved BOOLEAN DEFAULT 0,
                excluded_from_shuffle BOOLEAN DEFAULT 0,
                added_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                play_duration_total REAL DEFAULT 0,
                skip_after_seconds REAL,
                file_path_display TEXT,
                content_hash TEXT,
                disabled BOOLEAN DEFAULT 0,
                album_track_sort_key TEXT,
                cover_art_hash TEXT REFERENCES cover_art(hash)
            )
            """
        )
    }

    // swiftlint:enable function_body_length

    private static func createPlaylistsTable(in db: GRDB.Database) throws {
        try db.execute(
            sql: """
            CREATE TABLE playlists (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL,
                is_smart BOOLEAN DEFAULT 0,
                smart_criteria TEXT,
                sort_order INTEGER,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                parent_id INTEGER REFERENCES playlists(id),
                cover_art_path TEXT
            )
            """
        )
    }

    private static func createPlaylistTracksTable(in db: GRDB.Database) throws {
        try db.execute(
            sql: """
            CREATE TABLE playlist_tracks (
                playlist_id INTEGER REFERENCES playlists(id) ON DELETE CASCADE,
                track_id INTEGER REFERENCES tracks(id) ON DELETE CASCADE,
                position INTEGER NOT NULL,
                PRIMARY KEY (playlist_id, position)
            )
            """
        )
    }

    private static func createLyricsTable(in db: GRDB.Database) throws {
        try db.execute(
            sql: """
            CREATE TABLE lyrics (
                track_id INTEGER PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,
                lyrics_text TEXT,
                is_synced BOOLEAN DEFAULT 0,
                source TEXT
            )
            """
        )
    }

    private static func createScrobbleQueueTable(in db: GRDB.Database) throws {
        try db.execute(
            sql: """
            CREATE TABLE scrobble_queue (
                id INTEGER PRIMARY KEY,
                track_id INTEGER REFERENCES tracks(id) ON DELETE CASCADE,
                played_at INTEGER NOT NULL,
                duration_played REAL,
                submitted BOOLEAN DEFAULT 0,
                submission_attempts INTEGER DEFAULT 0
            )
            """
        )
    }

    // MARK: - Cover art table

    private static func createCoverArtTable(in db: GRDB.Database) throws {
        try db.execute(
            sql: """
            CREATE TABLE cover_art (
                hash TEXT PRIMARY KEY,
                path TEXT NOT NULL,
                width INTEGER,
                height INTEGER,
                format TEXT,
                byte_size INTEGER,
                source TEXT
            )
            """
        )
    }

    // MARK: - Play history table

    private static func createPlayHistoryTable(in db: GRDB.Database) throws {
        try db.execute(
            sql: """
            CREATE TABLE play_history (
                id INTEGER PRIMARY KEY,
                track_id INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
                played_at INTEGER NOT NULL,
                duration_played REAL NOT NULL,
                source TEXT
            )
            """
        )
    }

    // MARK: - Settings / metadata tables

    private static func createSettingsTables(in db: GRDB.Database) throws {
        try db.execute(
            sql: """
            CREATE TABLE settings (
                key TEXT PRIMARY KEY,
                value BLOB NOT NULL,
                updated_at INTEGER NOT NULL
            )
            """
        )
        try db.execute(
            sql: """
            CREATE TABLE app_metadata (
                key TEXT PRIMARY KEY,
                value TEXT
            )
            """
        )
    }

    // MARK: - FTS virtual tables

    private static func createFTSTables(in db: GRDB.Database) throws {
        try db.execute(
            sql: """
            CREATE VIRTUAL TABLE tracks_fts USING fts5(
                title, composer, genre, artist_name, album_title,
                tokenize='unicode61 remove_diacritics 2'
            )
            """
        )
        try db.execute(
            sql: """
            CREATE VIRTUAL TABLE artists_fts USING fts5(
                name, sort_name,
                tokenize='unicode61 remove_diacritics 2'
            )
            """
        )
        try db.execute(
            sql: """
            CREATE VIRTUAL TABLE albums_fts USING fts5(
                title,
                tokenize='unicode61 remove_diacritics 2'
            )
            """
        )
    }

    // MARK: - FTS triggers for tracks

    private static func createTrackFTSTriggers(in db: GRDB.Database) throws {
        try db.execute(
            sql: """
            CREATE TRIGGER tracks_ai AFTER INSERT ON tracks BEGIN
                INSERT INTO tracks_fts(rowid, title, composer, genre, artist_name, album_title)
                SELECT
                    NEW.id,
                    COALESCE(NEW.title, ''),
                    COALESCE(NEW.composer, ''),
                    COALESCE(NEW.genre, ''),
                    COALESCE((SELECT name FROM artists WHERE id = NEW.artist_id), ''),
                    COALESCE((SELECT title FROM albums WHERE id = NEW.album_id), '');
            END
            """
        )
        try db.execute(
            sql: """
            CREATE TRIGGER tracks_au AFTER UPDATE ON tracks BEGIN
                DELETE FROM tracks_fts WHERE rowid = OLD.id;
                INSERT INTO tracks_fts(rowid, title, composer, genre, artist_name, album_title)
                SELECT
                    NEW.id,
                    COALESCE(NEW.title, ''),
                    COALESCE(NEW.composer, ''),
                    COALESCE(NEW.genre, ''),
                    COALESCE((SELECT name FROM artists WHERE id = NEW.artist_id), ''),
                    COALESCE((SELECT title FROM albums WHERE id = NEW.album_id), '');
            END
            """
        )
        try db.execute(
            sql: """
            CREATE TRIGGER tracks_ad AFTER DELETE ON tracks BEGIN
                DELETE FROM tracks_fts WHERE rowid = OLD.id;
            END
            """
        )
    }

    // MARK: - FTS triggers for artists

    private static func createArtistFTSTriggers(in db: GRDB.Database) throws {
        try db.execute(
            sql: """
            CREATE TRIGGER artists_ai AFTER INSERT ON artists BEGIN
                INSERT INTO artists_fts(rowid, name, sort_name)
                VALUES(NEW.id, COALESCE(NEW.name, ''), COALESCE(NEW.sort_name, ''));
            END
            """
        )
        try db.execute(
            sql: """
            CREATE TRIGGER artists_au AFTER UPDATE ON artists BEGIN
                DELETE FROM artists_fts WHERE rowid = OLD.id;
                INSERT INTO artists_fts(rowid, name, sort_name)
                VALUES(NEW.id, COALESCE(NEW.name, ''), COALESCE(NEW.sort_name, ''));
            END
            """
        )
        try db.execute(
            sql: """
            CREATE TRIGGER artists_ad AFTER DELETE ON artists BEGIN
                DELETE FROM artists_fts WHERE rowid = OLD.id;
            END
            """
        )
    }

    // MARK: - FTS triggers for albums

    private static func createAlbumFTSTriggers(in db: GRDB.Database) throws {
        try db.execute(
            sql: """
            CREATE TRIGGER albums_ai AFTER INSERT ON albums BEGIN
                INSERT INTO albums_fts(rowid, title) VALUES(NEW.id, COALESCE(NEW.title, ''));
            END
            """
        )
        try db.execute(
            sql: """
            CREATE TRIGGER albums_au AFTER UPDATE ON albums BEGIN
                DELETE FROM albums_fts WHERE rowid = OLD.id;
                INSERT INTO albums_fts(rowid, title) VALUES(NEW.id, COALESCE(NEW.title, ''));
            END
            """
        )
        try db.execute(
            sql: """
            CREATE TRIGGER albums_ad AFTER DELETE ON albums BEGIN
                DELETE FROM albums_fts WHERE rowid = OLD.id;
            END
            """
        )
    }

    // MARK: - Indexes

    private static func createIndexes(in db: GRDB.Database) throws {
        let indexSQL = [
            "CREATE INDEX idx_tracks_artist ON tracks(artist_id)",
            "CREATE INDEX idx_tracks_album_artist ON tracks(album_artist_id)",
            "CREATE INDEX idx_tracks_album ON tracks(album_id)",
            "CREATE INDEX idx_tracks_added_at ON tracks(added_at DESC)",
            "CREATE INDEX idx_tracks_last_played ON tracks(last_played_at DESC)",
            "CREATE INDEX idx_tracks_play_count ON tracks(play_count DESC)",
            "CREATE INDEX idx_tracks_rating ON tracks(rating)",
            "CREATE INDEX idx_tracks_genre ON tracks(genre)",
            "CREATE INDEX idx_tracks_year ON tracks(year)",
            "CREATE INDEX idx_tracks_loved ON tracks(loved) WHERE loved = 1",
            "CREATE INDEX idx_tracks_file_mtime ON tracks(file_mtime)",
            "CREATE UNIQUE INDEX idx_tracks_file_url ON tracks(file_url)",
            "CREATE INDEX idx_pt_track ON playlist_tracks(track_id)",
            "CREATE INDEX idx_pt_playlist ON playlist_tracks(playlist_id)",
            "CREATE INDEX idx_scrobble_unsubmitted ON scrobble_queue(submitted) WHERE submitted = 0",
            "CREATE INDEX idx_play_history_track ON play_history(track_id)",
            "CREATE INDEX idx_play_history_played_at ON play_history(played_at DESC)",
        ]
        for sql in indexSQL {
            try db.execute(sql: sql)
        }
    }

    // MARK: - Seed data

    private static func seedMetadata(in db: GRDB.Database) throws {
        let now = Int64(Date().timeIntervalSince1970)
        let uuid = UUID().uuidString
        let rows: [(String, String)] = [
            ("schema_version", "1"),
            ("created_at", String(now)),
            ("library_uuid", uuid),
        ]
        for (key, value) in rows {
            try db.execute(
                sql: "INSERT INTO app_metadata(key, value) VALUES (?, ?)",
                arguments: [key, value]
            )
        }
    }
}
