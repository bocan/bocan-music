import GRDB

/// Migration 051: `artists.musicbrainz_fetched_at` (issue #401).
///
/// Records when an artist's MusicBrainz entity was last looked up, so the
/// enrichment job that fills `disambiguation` (and a missing `sort_name`)
/// visits each artist once instead of re-querying the whole library at 1
/// request/second on every launch. NULL means never fetched.
enum M051ArtistMusicBrainzFetchedAt {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("051_artist_musicbrainz_fetched_at") { db in
            try db.alter(table: "artists") { table in
                table.add(column: "musicbrainz_fetched_at", .integer)
            }
        }
    }
}
