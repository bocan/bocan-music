import GRDB

// MARK: - Collection card queries

/// Queries backing the collection-browsing grids (Artists / Genres / Composers).
///
/// These live in their own file because `AlbumRepository.swift` is near the
/// 500-line lint ceiling. All queries exclude disabled tracks, consistent with
/// ``AlbumRepository/fetchTrackCounts()``.
public extension AlbumRepository {
    /// Cover-art paths per artist, up to `maxPerArtist` each, ordered by album
    /// year DESC then title (deterministic) so a card's mosaic is stable across
    /// launches.
    ///
    /// Membership matches `ArtistRepository.fetchAlbumCounts` exactly: an
    /// artist's albums are the distinct albums that contain at least one
    /// non-disabled track *by that artist* (`tracks.artist_id`), regardless of
    /// who the album artist is. Grouping on `album_artist_id` instead would
    /// undercount compilation appearances — a five-album artist whose covers
    /// mostly live on "Various Artists" releases would show only the handful of
    /// albums credited to them, and a single-album artist whose album has no
    /// album artist would show none at all. Keying on the track artist keeps the
    /// mosaic in step with the "N albums" subtitle.
    ///
    /// Albums with no cover art are excluded; an artist all of whose albums lack
    /// art yields an empty list and renders a placeholder tile.
    func fetchCoverArtPathsByArtist(maxPerArtist: Int = 4)
        async throws -> [Int64: [String]] {
        try await self.database.read { db in
            // One row per (artist, album): GROUP BY collapses the many tracks an
            // artist may have on one album down to that album's single cover.
            let rows = try Row.fetchAll(db, sql: """
                SELECT t.artist_id AS artist_id, al.cover_art_path AS cover_art_path
                FROM tracks t
                JOIN albums al ON al.id = t.album_id
                WHERE t.disabled = 0
                  AND t.artist_id IS NOT NULL
                  AND al.cover_art_path IS NOT NULL
                GROUP BY t.artist_id, al.id
                ORDER BY al.year DESC, al.title
            """)
            var result: [Int64: [String]] = [:]
            for row in rows {
                guard let artistID: Int64 = row["artist_id"],
                      let path: String = row["cover_art_path"] else { continue }
                // The rows arrive pre-ordered; dedupe shared cover paths and keep
                // only the first `maxPerArtist` per artist to bound the mosaic.
                var paths = result[artistID, default: []]
                guard paths.count < maxPerArtist, !paths.contains(path) else { continue }
                paths.append(path)
                result[artistID] = paths
            }
            return result
        }
    }
}
