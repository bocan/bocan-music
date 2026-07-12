import GRDB

/// Adds `artwork_hash` to `podcasts`: the lowercase-hex SHA-256 of the show's
/// cached artwork file (`artwork_path`), computed once when the art is cached.
/// Phone Sync (phase 22-10) advertises it as the manifest `artworkHash` and
/// resolves it back to the file in `GET /v1/artwork/{hash}`. Shows cached
/// before this migration carry a NULL hash until the one-shot backfill (or the
/// next artwork cache) populates it.
enum M033PodcastArtworkHash {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("033_podcast_artwork_hash") { db in
            try db.execute(sql: "ALTER TABLE podcasts ADD COLUMN artwork_hash TEXT")
        }
    }
}
