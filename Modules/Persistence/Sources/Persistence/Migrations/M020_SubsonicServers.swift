import GRDB

/// Phase 19 — Subsonic / Navidrome / OpenSubsonic client.
///
/// 1. Creates `subsonic_servers` — one row per configured remote server.
/// 2. Creates `subsonic_metadata_cache` — ephemeral metadata snapshots keyed
///    by (server_id, entity_kind, entity_id). Rows older than 7 days are
///    purged on launch by `SubsonicServerRepository.pruneStaleCache()`.
enum M020SubsonicServers {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("020_subsonic_servers") { db in
            try db.execute(
                sql: """
                CREATE TABLE subsonic_servers (
                    id                    TEXT PRIMARY KEY,
                    name                  TEXT NOT NULL,
                    server_url            TEXT NOT NULL,
                    auth_kind             TEXT NOT NULL,
                    username              TEXT,
                    keychain_account      TEXT NOT NULL,
                    allow_self_signed_tls INTEGER NOT NULL DEFAULT 0,
                    max_bitrate           TEXT NOT NULL DEFAULT 'original',
                    preferred_format      TEXT NOT NULL DEFAULT 'original',
                    precache_next         INTEGER NOT NULL DEFAULT 1,
                    include_in_search     INTEGER NOT NULL DEFAULT 1,
                    show_in_sidebar       INTEGER NOT NULL DEFAULT 1,
                    scrobble              INTEGER NOT NULL DEFAULT 1,
                    sync_stars            INTEGER NOT NULL DEFAULT 1,
                    sync_ratings          INTEGER NOT NULL DEFAULT 1,
                    sort_index            INTEGER NOT NULL DEFAULT 0,
                    created_at            REAL NOT NULL,
                    last_connected_at     REAL,
                    capabilities_json     BLOB
                )
                """
            )
            try db.execute(
                sql: """
                CREATE UNIQUE INDEX subsonic_servers_name_idx ON subsonic_servers(name)
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE subsonic_metadata_cache (
                    server_id    TEXT NOT NULL,
                    entity_kind  TEXT NOT NULL,
                    entity_id    TEXT NOT NULL,
                    payload_json BLOB NOT NULL,
                    fetched_at   REAL NOT NULL,
                    PRIMARY KEY (server_id, entity_kind, entity_id)
                )
                """
            )
            try db.execute(
                sql: """
                CREATE INDEX idx_subsonic_cache_server ON subsonic_metadata_cache(server_id)
                """
            )
        }
    }
}
