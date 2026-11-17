import GRDB

/// ADR-097: Jellyfin as a source beside Subsonic.
///
/// 1. Creates `jellyfin_servers`: one row per configured Jellyfin server. It
///    mirrors `subsonic_servers` (M020) and leaves out what Jellyfin does not
///    need: `auth_kind` (one method), `keychain_account` (always the server id),
///    `sync_ratings` (Jellyfin has no star rating) and `capabilities_json`
///    (no row is gated on a capability).
/// 2. Creates `jellyfin_metadata_cache`: ephemeral metadata snapshots keyed by
///    (server_id, entity_kind, entity_id). Rows older than 7 days are purged on
///    launch by `JellyfinServerRepository.pruneStaleCache()`.
///
/// The access token is never stored here. It lives in the login Keychain.
enum M055JellyfinServers {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("055_jellyfin_servers") { db in
            try db.execute(
                sql: """
                CREATE TABLE jellyfin_servers (
                    id                    TEXT PRIMARY KEY,
                    name                  TEXT NOT NULL,
                    server_url            TEXT NOT NULL,
                    user_id               TEXT NOT NULL,
                    username              TEXT,
                    device_id             TEXT NOT NULL,
                    allow_self_signed_tls INTEGER NOT NULL DEFAULT 0,
                    max_bitrate           TEXT NOT NULL DEFAULT 'original',
                    preferred_format      TEXT NOT NULL DEFAULT 'original',
                    precache_next         INTEGER NOT NULL DEFAULT 1,
                    include_in_search     INTEGER NOT NULL DEFAULT 1,
                    show_in_sidebar       INTEGER NOT NULL DEFAULT 1,
                    scrobble              INTEGER NOT NULL DEFAULT 1,
                    sync_stars            INTEGER NOT NULL DEFAULT 1,
                    sort_index            INTEGER NOT NULL DEFAULT 0,
                    created_at            REAL NOT NULL,
                    last_connected_at     REAL
                )
                """
            )
            try db.execute(
                sql: """
                CREATE UNIQUE INDEX jellyfin_servers_name_idx ON jellyfin_servers(name)
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE jellyfin_metadata_cache (
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
                CREATE INDEX idx_jellyfin_cache_server ON jellyfin_metadata_cache(server_id)
                """
            )
        }
    }
}
