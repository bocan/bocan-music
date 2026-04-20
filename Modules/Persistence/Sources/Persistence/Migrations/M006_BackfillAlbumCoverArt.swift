import Foundation
import GRDB

/// Migration 006: backfills `albums.cover_art_hash` / `albums.cover_art_path`
/// from tracks that already have cover-art linked.
///
/// For each album without a cover, picks the most common `cover_art_hash`
/// among its tracks and copies the corresponding path out of `cover_art`.
/// Albums whose tracks have no cover art are left alone.
enum M006BackfillAlbumCoverArt {
    static func register(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("006_backfill_album_cover_art") { db in
            try db.execute(sql: """
                UPDATE albums
                   SET cover_art_hash = (
                       SELECT t.cover_art_hash
                         FROM tracks t
                        WHERE t.album_id = albums.id
                          AND t.cover_art_hash IS NOT NULL
                        GROUP BY t.cover_art_hash
                        ORDER BY COUNT(*) DESC, t.cover_art_hash ASC
                        LIMIT 1
                   )
                 WHERE cover_art_hash IS NULL
            """)

            try db.execute(sql: """
                UPDATE albums
                   SET cover_art_path = (
                       SELECT ca.path FROM cover_art ca
                        WHERE ca.hash = albums.cover_art_hash
                   )
                 WHERE cover_art_hash IS NOT NULL
                   AND cover_art_path IS NULL
            """)
        }
    }
}
