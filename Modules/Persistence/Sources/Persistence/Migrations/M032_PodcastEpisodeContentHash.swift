import GRDB

/// Adds `content_hash` to `podcast_episode_state`: a downloaded episode's SHA-256,
/// computed once at download time. Phone Sync (phase 22) uses it as the episode
/// ETag / `If-Match` value and to avoid re-hashing files when building a manifest.
/// Rows downloaded before this migration have a NULL hash until re-downloaded.
enum M032PodcastEpisodeContentHash {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("032_podcast_episode_content_hash") { db in
            try db.execute(sql: "ALTER TABLE podcast_episode_state ADD COLUMN content_hash TEXT")
        }
    }
}
