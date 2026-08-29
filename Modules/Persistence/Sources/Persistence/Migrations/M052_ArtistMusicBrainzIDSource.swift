import GRDB

/// Migration 052: `artists.musicbrainz_id_source` (issue #413).
///
/// Where an artist's MusicBrainz id came from: `tag` when the scanner read it
/// from the files, `search` when the user confirmed a Deep Dive name match.
/// A tagged id always wins over a confirmed guess, so a later Picard pass
/// corrects a wrong confirmation. Existing ids all came from tags.
enum M052ArtistMusicBrainzIDSource {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("052_artist_musicbrainz_id_source") { db in
            try db.alter(table: "artists") { table in
                table.add(column: "musicbrainz_id_source", .text)
            }
            try self.apply(db)
        }
    }

    /// The backfill, callable from tests against a populated table.
    static func apply(_ db: GRDB.Database) throws {
        try db.execute(
            sql: "UPDATE artists SET musicbrainz_id_source = ? WHERE musicbrainz_artist_id IS NOT NULL AND musicbrainz_id_source IS NULL",
            arguments: [Artist.MBIDSource.tag.rawValue]
        )
    }
}
