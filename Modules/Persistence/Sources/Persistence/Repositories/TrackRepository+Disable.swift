import Foundation
import GRDB

/// The bulk soft-deletes, split from the core CRUD so each file stays inside
/// the lint length limit. A soft delete sets `disabled = 1` and keeps the row,
/// so ratings, play counts and playlist entries survive until the file is
/// imported again (ADR-003).
public extension TrackRepository {
    /// Soft-deletes every enabled track whose `file_url` is inside the
    /// directory `directoryURL`, and returns how many rows changed.
    ///
    /// `directoryURL` must be in the stored form, a `file://` URL string as
    /// `URL.absoluteString` gives it, never a plain path: `file_url` holds
    /// percent-encoded URLs, so a path such as `/Volumes/Music` matches no row
    /// (#643). The comparison is an exact prefix on whole path components, so
    /// `%` and `_` in a folder name are literal.
    @discardableResult
    func disableAll(underDirectoryURL directoryURL: String) async throws -> Int {
        let prefix = directoryURL.hasSuffix("/") ? directoryURL : directoryURL + "/"
        let count: Int = try await self.database.write { db in
            try db.execute(
                sql: "UPDATE tracks SET disabled = 1 WHERE disabled = 0 AND substr(file_url, 1, ?) = ?",
                // SQLite's substr counts Unicode scalars, not Swift characters.
                arguments: [prefix.unicodeScalars.count, prefix]
            )
            return db.changesCount
        }
        self.log.info("track.disableAll", ["prefix": prefix, "count": count])
        return count
    }

    /// The `file_url` of every enabled track, keyed by track id.
    ///
    /// For callers that decide in Swift which tracks a folder holds (symlinks
    /// and percent-encoding make that more than a string prefix), without
    /// loading whole rows.
    func enabledFileURLs() async throws -> [Int64: String] {
        try await self.database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, file_url FROM tracks WHERE disabled = 0")
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["id"] as Int64, $0["file_url"] as String) })
        }
    }

    /// Soft-deletes the tracks in `ids` in one transaction and returns how
    /// many rows changed. All or nothing: a failure rolls every row back.
    @discardableResult
    func disable(ids: [Int64]) async throws -> Int {
        guard !ids.isEmpty else { return 0 }
        let count: Int = try await self.database.write { db in
            var changed = 0
            // Chunked to stay far below SQLite's bound-parameter limit.
            for start in stride(from: 0, to: ids.count, by: 500) {
                let chunk = Array(ids[start ..< min(start + 500, ids.count)])
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                try db.execute(
                    sql: "UPDATE tracks SET disabled = 1 WHERE disabled = 0 AND id IN (\(marks))",
                    arguments: StatementArguments(chunk)
                )
                changed += db.changesCount
            }
            return changed
        }
        self.log.info("track.disable.batch", ["count": count])
        return count
    }

    /// Deletes the album and artist rows that no enabled track uses, in one
    /// transaction, and returns how many of each went.
    ///
    /// Run after tracks are soft-deleted on purpose (Remove from Library, a
    /// removed folder), so their albums and artists do not stay behind as
    /// empty entries. Not for a scan that found files missing: the drive may
    /// only be unplugged, and the album rows carry settings worth keeping.
    @discardableResult
    func pruneAlbumsAndArtistsWithoutEnabledTracks() async throws -> (albums: Int, artists: Int) {
        try await self.database.write { db in
            try db.execute(sql: """
            DELETE FROM albums
            WHERE id NOT IN (
                SELECT DISTINCT album_id FROM tracks
                WHERE album_id IS NOT NULL
                  AND (disabled IS NULL OR disabled = 0)
            )
            """)
            let albums = db.changesCount
            try db.execute(sql: """
            DELETE FROM artists
            WHERE id NOT IN (
                SELECT DISTINCT artist_id FROM tracks
                WHERE artist_id IS NOT NULL
                  AND (disabled IS NULL OR disabled = 0)
                UNION
                SELECT DISTINCT album_artist_id FROM tracks
                WHERE album_artist_id IS NOT NULL
                  AND (disabled IS NULL OR disabled = 0)
                UNION
                SELECT DISTINCT album_artist_id FROM albums
                WHERE album_artist_id IS NOT NULL
            )
            """)
            return (albums, db.changesCount)
        }
    }
}
