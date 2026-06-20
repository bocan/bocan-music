import GRDB

/// Migration 027: per-show podcast settings on the `podcasts` table.
///
/// Four nullable columns (see `docs/design-spec/phase21-12-h-per-show-settings.md`):
/// - `playback_speed`  REAL    -- user override; nil = use the app default rate.
/// - `episode_sort`    TEXT    -- 'newest' | 'oldest'; nil = derive from show_type.
/// - `retention_limit` INTEGER -- keep newest N content rows; nil = keep all.
/// - `show_type`       TEXT    -- 'episodic' | 'serial' from itunes:type (feed-derived).
///
/// Nullable so existing rows stay valid; `show_type` populates on the next
/// refresh and the overrides stay nil until the user sets them.
enum M027PodcastPerShowSettings {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("027_podcast_per_show_settings") { db in
            try db.alter(table: "podcasts") { table in
                table.add(column: "playback_speed", .double)
                table.add(column: "episode_sort", .text)
                table.add(column: "retention_limit", .integer)
                table.add(column: "show_type", .text)
            }
        }
    }
}
