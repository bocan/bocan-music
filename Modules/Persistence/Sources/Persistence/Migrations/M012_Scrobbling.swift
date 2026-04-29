import GRDB

/// Phase 13 — scrobbling.
///
/// 1. Adds `dead` flag to `scrobble_queue` (a row that has exhausted its retries).
/// 2. Creates a unique index on `(track_id, played_at)` so duplicate enqueues of the
///    same play event are silently ignored (`INSERT OR IGNORE`).
/// 3. Creates `scrobble_submissions` — a join table that tracks per-provider
///    submission state for each queued play, so multiple providers (Last.fm,
///    ListenBrainz) can each record their own success/failure independently.
enum M012Scrobbling {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("012_scrobbling") { db in
            try db.alter(table: "scrobble_queue") { table in
                table.add(column: "dead", .boolean).defaults(to: false)
                table.add(column: "last_error", .text)
            }

            try db.execute(
                sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS uniq_scrobble_queue_track_playedat
                ON scrobble_queue(track_id, played_at)
                """
            )

            try db.execute(
                sql: """
                CREATE TABLE scrobble_submissions (
                    queue_id INTEGER NOT NULL REFERENCES scrobble_queue(id) ON DELETE CASCADE,
                    provider_id TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'pending',
                    submitted_at INTEGER,
                    attempts INTEGER NOT NULL DEFAULT 0,
                    next_attempt_at INTEGER,
                    last_error TEXT,
                    PRIMARY KEY (queue_id, provider_id)
                )
                """
            )

            try db.execute(
                sql: """
                CREATE INDEX idx_scrobble_submissions_pending
                ON scrobble_submissions(provider_id, status, next_attempt_at)
                WHERE status IN ('pending', 'retry')
                """
            )
        }
    }
}
