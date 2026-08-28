import GRDB

/// Migration 042: backfill `albums.musicbrainz_release_id` / `_release_group_id`.
///
/// Both columns existed since M001 and the per-track values were imported
/// from Picard tags, but nothing rolled them up (issue #402), which also made
/// the Library Hygiene "Albums Missing MusicBrainz ID" line report every
/// album. Applies `AlbumRepository.musicBrainzRollupSQL` to every album once;
/// the importer and edit transaction keep it current afterwards.
enum M042AlbumMusicBrainzBackfill {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("042_album_musicbrainz_backfill") { db in
            try db.execute(sql: AlbumRepository.musicBrainzRollupSQL)
        }
    }
}
