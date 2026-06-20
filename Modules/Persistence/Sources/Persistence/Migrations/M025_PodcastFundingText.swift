import GRDB

/// Migration 025: adds the `funding_text` column to the `podcasts` table.
///
/// Holds the human label from Podcasting 2.0 `podcast:funding` (the text between
/// the element tags), now that the supplementary namespace parser fills it. See
/// `docs/design-spec/phase21-12-a-namespace-supplement.md`.
///
/// Nullable so existing rows stay valid; populated on the next feed refresh.
/// `funding_url` and `chapters_url` already exist (M023); only the label is new.
enum M025PodcastFundingText {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("025_podcast_funding_text") { db in
            try db.alter(table: "podcasts") { table in
                table.add(column: "funding_text", .text)
            }
        }
    }
}
