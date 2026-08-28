import GRDB

/// Migration 043: track-artist MBIDs (issue #399).
///
/// Adds `tracks.musicbrainz_artist_id` for Picard's `MUSICBRAINZ_ARTISTID`,
/// which the bridge never read before, and backfills the long-empty
/// `artists.musicbrainz_artist_id` from the album-artist MBIDs the tracks
/// already carry (most common value per album artist). Track-only artists
/// get theirs on the next full rescan, once the new column is populated and
/// `ArtistRepository.findOrCreate(name:sortName:musicbrainzID:)` sees it.
enum M043ArtistMusicBrainzID {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("043_artist_musicbrainz_id") { db in
            try db.alter(table: "tracks") { table in
                table.add(column: "musicbrainz_artist_id", .text)
            }
            try db.execute(sql: """
            UPDATE artists SET musicbrainz_artist_id = (
                SELECT musicbrainz_album_artist_id FROM tracks
                WHERE album_artist_id = artists.id
                  AND musicbrainz_album_artist_id IS NOT NULL AND musicbrainz_album_artist_id <> ''
                GROUP BY musicbrainz_album_artist_id
                ORDER BY COUNT(*) DESC, musicbrainz_album_artist_id
                LIMIT 1
            )
            WHERE musicbrainz_artist_id IS NULL
            """)
        }
    }
}
