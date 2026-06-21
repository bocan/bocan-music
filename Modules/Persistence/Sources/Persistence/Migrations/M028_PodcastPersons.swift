import GRDB

/// Migration 028: Podcasting 2.0 `podcast:person` credits.
///
/// One nullable JSON blob column on each of `podcasts` (show-level "regular" people)
/// and `podcast_episodes` (episode-level people, which replace the show's for that
/// episode). Feed-derived content, refreshed on every parse; nil for existing rows
/// until the next refresh populates it from a feed that carries the tag.
enum M028PodcastPersons {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("028_podcast_persons") { db in
            try db.alter(table: "podcasts") { table in
                table.add(column: "persons_json", .blob)
            }
            try db.alter(table: "podcast_episodes") { table in
                table.add(column: "persons_json", .blob)
            }
        }
    }
}
