import GRDB

/// Migration 050: drop `podcasts.subscribed` and `podcasts.sort_index` (issue #416).
///
/// `subscribed` encoded a soft-unsubscribe design that ADR-041 replaced with a
/// hard delete, so it could never be false and every filter on it was a
/// no-op. `sort_index` backed a drag-to-reorder that ADR-044 parked and no UI
/// ever called; shows order by title. Both were at their default on every row.
enum M050DropPodcastSubscribedSortIndex {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("050_drop_podcast_subscribed_sort_index") { db in
            try db.alter(table: "podcasts") { table in
                table.drop(column: "subscribed")
                table.drop(column: "sort_index")
            }
        }
    }
}
