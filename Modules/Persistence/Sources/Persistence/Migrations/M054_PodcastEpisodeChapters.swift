import GRDB

/// Migration 054: adds the `podcast_episode_chapters` cache table (#608).
///
/// Stores the Podcasting 2.0 chapters document of an episode as fetched, so
/// Phone Sync can serve `GET /v1/chapters/{episodeId}` from the database (a
/// serving handler makes no outbound request) and the chapter list still loads
/// when the Mac is offline. It is a re-fetchable cache keyed by the stable
/// `(podcast_id, guid)` identity, like `podcast_episode_transcript` (M026).
///
/// `source_url` is the `chapters_url` the body came from. A row counts only
/// while it still equals the episode's `chapters_url`, so a feed that moves
/// its chapters retires the old document without a delete.
///
/// `ON DELETE CASCADE` mirrors the other podcast tables, so unsubscribing drops
/// the cache. No index beyond the PK: every lookup is by `(podcast_id, guid)`.
enum M054PodcastEpisodeChapters {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("054_podcast_episode_chapters") { db in
            try db.execute(sql: """
            CREATE TABLE podcast_episode_chapters (
                podcast_id  INTEGER NOT NULL REFERENCES podcasts(id) ON DELETE CASCADE,
                guid        TEXT NOT NULL,
                content     TEXT NOT NULL,
                source_url  TEXT NOT NULL,
                PRIMARY KEY (podcast_id, guid)
            )
            """)
        }
    }
}
