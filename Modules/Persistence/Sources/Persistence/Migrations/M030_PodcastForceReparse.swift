import GRDB

/// Migration 030: force one full re-parse of every podcast subscription.
///
/// The Podcasting 2.0 `podcast:person` (M028) and `podcast:podroll` (M029) columns
/// are feed-derived: they only populate when a feed is fetched *and* parsed. But
/// `PodcastService.refresh` sends a conditional GET, and a `304 Not Modified`
/// short-circuits before the parse runs. A subscription whose bytes have not
/// changed since the upgrade therefore keeps NULL `persons_json` / `podroll_json`
/// forever, because it answers 304 on every refresh and never re-parses.
///
/// Clearing the stored HTTP validators makes the next refresh fall through to a
/// full `200` GET and a parse, backfilling those columns once. The validators
/// repopulate from that response, so normal conditional-GET / 304 behaviour
/// resumes immediately afterwards. This is a one-time, idempotent repair; it
/// touches no user-owned state.
enum M030PodcastForceReparse {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("030_podcast_force_reparse") { db in
            try db.execute(sql: "UPDATE podcasts SET http_etag = NULL, http_last_modified = NULL")
        }
    }
}
