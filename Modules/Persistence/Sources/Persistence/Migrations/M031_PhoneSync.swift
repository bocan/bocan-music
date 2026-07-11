import GRDB

/// Phase 22 — Phone Sync server.
///
/// 1. `trusted_devices` — one row per paired phone, pinned by its client-cert
///    SHA-256 fingerprint. This set is the whole trust decision after pairing:
///    a fingerprint absent here is refused at the TLS layer.
/// 2. `sync_meta` — a singleton row (`id = 1`) holding the stable per-Mac
///    `server_id` and the monotonic `generation` counter the phone polls via
///    `/v1/ping`. Seeded lazily by the sync-meta repository in phase 22-5.
/// 3. `sync_profile` — a singleton row (`id = 1`) holding the encoded
///    `SyncProfile` describing what a phone may see. Seeded lazily in phase 22-5.
///
/// The server's own private key and certificate live in the Keychain, never
/// here; `trusted_devices` stores only each phone's public certificate.
enum M031PhoneSync {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("031_phone_sync") { db in
            try db.execute(
                sql: """
                CREATE TABLE trusted_devices (
                    fingerprint TEXT PRIMARY KEY,
                    cert_der    BLOB NOT NULL,
                    device_name TEXT NOT NULL,
                    paired_at   REAL NOT NULL
                )
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE sync_meta (
                    id         INTEGER PRIMARY KEY CHECK (id = 1),
                    server_id  TEXT NOT NULL,
                    generation INTEGER NOT NULL DEFAULT 0
                )
                """
            )
            try db.execute(
                sql: """
                CREATE TABLE sync_profile (
                    id           INTEGER PRIMARY KEY CHECK (id = 1),
                    profile_json BLOB NOT NULL
                )
                """
            )
        }
    }
}
