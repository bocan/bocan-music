import GRDB

/// Phase 21.1 - Podcast subscriptions, episode content, and per-episode playback state.
///
/// Three tables are created together in one migration:
///   - `podcasts` - one row per subscribed show
///   - `podcast_episodes` - episode content (refreshable; never stores user state)
///   - `podcast_episode_state` - user progress keyed by (podcast_id, guid); precious, never clobbered by a refresh
///
/// State lives in a separate table so a feed refresh can freely replace `podcast_episodes`
/// without resetting the user's resume position.
enum M023Podcasts {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("023_podcasts") { db in
            try Self.createPodcastsTable(in: db)
            try Self.createEpisodesTable(in: db)
            try Self.createStateTable(in: db)
        }
    }

    private static func createPodcastsTable(in db: GRDB.Database) throws {
        try db.execute(sql: """
        CREATE TABLE podcasts (
            id                    INTEGER PRIMARY KEY AUTOINCREMENT,
            feed_url              TEXT NOT NULL,
            title                 TEXT NOT NULL,
            author                TEXT,
            description           TEXT,
            artwork_url           TEXT,
            artwork_path          TEXT,
            link                  TEXT,
            language              TEXT,
            explicit              INTEGER NOT NULL DEFAULT 0,
            categories_json       BLOB,
            owner_name            TEXT,
            owner_email           TEXT,
            copyright             TEXT,
            funding_url           TEXT,
            itunes_collection_id  INTEGER,
            podcast_index_id      INTEGER,
            http_etag             TEXT,
            http_last_modified    TEXT,
            last_refreshed_at     REAL,
            last_refresh_error    TEXT,
            subscribed            INTEGER NOT NULL DEFAULT 1,
            auto_download         INTEGER NOT NULL DEFAULT 0,
            sort_index            INTEGER NOT NULL DEFAULT 0,
            added_at              REAL NOT NULL
        )
        """)
        try db.execute(sql: "CREATE UNIQUE INDEX podcasts_feed_url_idx ON podcasts(feed_url)")
    }

    private static func createEpisodesTable(in db: GRDB.Database) throws {
        try db.execute(sql: """
        CREATE TABLE podcast_episodes (
            id                INTEGER PRIMARY KEY AUTOINCREMENT,
            podcast_id        INTEGER NOT NULL REFERENCES podcasts(id) ON DELETE CASCADE,
            guid              TEXT NOT NULL,
            title             TEXT NOT NULL,
            subtitle          TEXT,
            description_html  TEXT,
            audio_url         TEXT NOT NULL,
            audio_mime        TEXT,
            audio_byte_length INTEGER,
            duration          REAL,
            published_at      REAL,
            season            INTEGER,
            episode_number    INTEGER,
            episode_type      TEXT,
            artwork_url       TEXT,
            artwork_path      TEXT,
            chapters_url      TEXT,
            transcript_url    TEXT,
            link              TEXT,
            explicit          INTEGER NOT NULL DEFAULT 0,
            added_at          REAL NOT NULL
        )
        """)
        try db.execute(sql: "CREATE UNIQUE INDEX podcast_episodes_guid_idx ON podcast_episodes(podcast_id, guid)")
        try db.execute(sql: "CREATE INDEX podcast_episodes_published_idx ON podcast_episodes(podcast_id, published_at DESC)")
    }

    private static func createStateTable(in db: GRDB.Database) throws {
        try db.execute(sql: """
        CREATE TABLE podcast_episode_state (
            podcast_id     INTEGER NOT NULL REFERENCES podcasts(id) ON DELETE CASCADE,
            guid           TEXT NOT NULL,
            play_position  REAL NOT NULL DEFAULT 0,
            play_state     TEXT NOT NULL DEFAULT 'unplayed',
            last_played_at REAL,
            completed_at   REAL,
            download_state TEXT NOT NULL DEFAULT 'none',
            download_path  TEXT,
            download_bytes INTEGER,
            PRIMARY KEY (podcast_id, guid)
        )
        """)
    }
}
