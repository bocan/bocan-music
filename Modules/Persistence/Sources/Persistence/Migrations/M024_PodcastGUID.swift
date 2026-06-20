import GRDB

/// Migration 024: adds the `podcast_guid` column to the `podcasts` table.
///
/// Captures the Podcasting 2.0 `podcast:guid` tag (a stable, cross-platform show
/// identity), now that FeedKit 10.4.0 parses the `podcast:` namespace. See
/// `docs/design-spec/phase21-11-feedkit-upgrade.md`.
///
/// Nullable so existing rows stay valid; populated on the next feed refresh. Not
/// unique, because feeds may share or omit the tag; `feed_url` remains the identity.
enum M024PodcastGUID {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("024_podcast_guid") { db in
            try db.alter(table: "podcasts") { table in
                table.add(column: "podcast_guid", .text)
            }
        }
    }
}
