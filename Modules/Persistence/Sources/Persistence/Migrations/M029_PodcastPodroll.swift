import GRDB

/// Migration 029: Podcasting 2.0 `podcast:podroll` recommendations.
///
/// One nullable JSON blob column on `podcasts` holding the channel-level list of
/// recommended shows (`podcast:remoteItem` entries). Feed-derived content,
/// refreshed on every parse; nil for existing rows until the next refresh
/// populates it from a feed that carries the tag.
enum M029PodcastPodroll {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("029_podcast_podroll") { db in
            try db.alter(table: "podcasts") { table in
                table.add(column: "podroll_json", .blob)
            }
        }
    }
}
