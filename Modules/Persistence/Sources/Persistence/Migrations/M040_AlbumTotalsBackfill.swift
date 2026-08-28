import GRDB

/// Migration 040: backfill `albums.total_tracks` / `albums.total_discs`.
///
/// Both columns existed since M001 but nothing ever wrote them (issue #404).
/// The importer now rolls tag-supplied totals up via
/// `AlbumRepository.recomputeTotals`; this one-off applies the same rule to
/// every existing album so the value is available without a full rescan.
/// Albums whose tracks carry no totals stay NULL (no guessing from the highest
/// track number, which would mask missing tracks). MP3 / M4A totals that the
/// old bridge failed to parse arrive on the next full rescan.
enum M040AlbumTotalsBackfill {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("040_album_totals_backfill") { db in
            try db.execute(
                sql: """
                UPDATE albums SET
                    total_tracks = (SELECT MAX(track_total) FROM tracks WHERE album_id = albums.id),
                    total_discs  = (SELECT MAX(disc_total)  FROM tracks WHERE album_id = albums.id)
                """
            )
        }
    }
}
