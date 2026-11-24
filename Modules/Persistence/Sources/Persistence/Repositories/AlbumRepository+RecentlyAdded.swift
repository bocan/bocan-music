import Foundation
import GRDB

// MARK: - Recently added albums (#700)

/// The album queries behind Recently Added's Albums mode and the "Date Added"
/// album sort (#700). An album's date is its newest song's `added_at`.
public extension AlbumRepository {
    /// Albums with at least one non-disabled track added in the last `days`
    /// days, newest addition first, then by title. An album's date is the
    /// newest `added_at` among its tracks, so an album that gained a song
    /// yesterday sorts as added yesterday, whatever its release year.
    ///
    /// The filter runs on `tracks.added_at` before the grouping, so the query
    /// reads only the recent tracks (`idx_tracks_added_at`), not the library.
    /// Within the window the newest recent track is also the album's newest
    /// track, so the order matches ``fetchLatestAddedAt()``. Tracks with a
    /// NULL `album_id` contribute no album.
    ///
    /// - Parameter now: the reference time, for tests; the window is the same
    ///   as `TrackRepository.recentlyAdded(days:)`.
    func fetchRecentlyAdded(days: Int = 30, now: Date = Date()) async throws -> [Album] {
        let cutoff = Int64(now.timeIntervalSince1970) - Int64(days * 86400)
        let sql = """
            SELECT al.*, MAX(t.added_at) AS latest_added_at
            FROM tracks t
            JOIN albums al ON al.id = t.album_id
            WHERE t.disabled = 0 AND t.added_at >= ?
            GROUP BY al.id
            ORDER BY latest_added_at DESC, al.title
        """
        return try await self.database.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: [cutoff])
            return try rows.map { try Album(row: $0) }
        }
    }

    /// Album ID to the newest `added_at` among its non-disabled tracks: the
    /// date the "Date Added" album sort orders by. Albums with no such track
    /// are absent.
    func fetchLatestAddedAt() async throws -> [Int64: Int64] {
        try await self.database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT album_id, MAX(added_at) AS latest
                FROM tracks
                WHERE disabled = 0 AND album_id IS NOT NULL
                GROUP BY album_id
            """)
            var result: [Int64: Int64] = [:]
            for row in rows {
                if let albumID: Int64 = row["album_id"], let latest: Int64 = row["latest"] {
                    result[albumID] = latest
                }
            }
            return result
        }
    }
}
