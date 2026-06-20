import GRDB

/// Migration 026: adds the `podcast_episode_transcript` cache table.
///
/// Stores fetched transcript bodies in full so the viewer works offline. It is a
/// re-fetchable cache keyed by the stable `(podcast_id, guid)` identity, cleaned
/// 30 days after the episode is played (see `TranscriptRepository`). See
/// `docs/design-spec/phase21-12-b-transcripts.md`.
///
/// `ON DELETE CASCADE` mirrors the other podcast tables, so unsubscribing drops
/// the cache. No index beyond the PK: lookups and the cleanup join are both by
/// `(podcast_id, guid)` over a small table.
enum M026PodcastTranscript {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("026_podcast_transcript") { db in
            try db.execute(sql: """
            CREATE TABLE podcast_episode_transcript (
                podcast_id  INTEGER NOT NULL REFERENCES podcasts(id) ON DELETE CASCADE,
                guid        TEXT NOT NULL,
                content     TEXT NOT NULL,
                format      TEXT NOT NULL,
                language    TEXT,
                source_url  TEXT NOT NULL,
                fetched_at  REAL NOT NULL,
                PRIMARY KEY (podcast_id, guid)
            )
            """)
        }
    }
}
