import GRDB

/// Migration 039: force one more full re-parse of every podcast subscription.
///
/// M030 cleared the HTTP validators so feeds would re-parse and backfill the
/// `podcast:person` columns. That worked for `podcasts.persons_json`, but
/// `podcast_episodes.persons_json` stayed NULL on every episode because the
/// hand-written `EpisodeRepository.upsertOne` statement omitted the column from
/// its INSERT and UPDATE (issue #411). Now that the upsert carries it, clear the
/// validators again so the next refresh falls through to a full `200` GET and
/// the episode credits finally land. One-time, idempotent, touches no
/// user-owned state; conditional-GET / 304 behaviour resumes right after.
enum M039PodcastForceReparsePersons {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("039_podcast_force_reparse_persons") { db in
            try db.execute(sql: "UPDATE podcasts SET http_etag = NULL, http_last_modified = NULL")
        }
    }
}
