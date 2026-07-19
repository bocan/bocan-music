import GRDB

// MARK: - CollectionCardData

/// One row of a genre or composer grid: the collection name, its counts, and up
/// to `maxCovers` deterministic cover-art paths for the mosaic. UI-agnostic.
public struct CollectionCardData: Sendable, Hashable {
    public let name: String
    public let albumCount: Int
    public let songCount: Int
    public let coverArtPaths: [String]

    public init(name: String, albumCount: Int, songCount: Int, coverArtPaths: [String]) {
        self.name = name
        self.albumCount = albumCount
        self.songCount = songCount
        self.coverArtPaths = coverArtPaths
    }
}

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

    /// One `CollectionCardData` per distinct genre. The genre set is identical to
    /// `TrackRepository.allGenres` (the list source): every non-null genre on a
    /// non-disabled track, empty string included. `albumCount` is the distinct
    /// album count (tracks with a null `album_id` count toward `songCount` but
    /// contribute no album or cover); cover paths are deduped and deterministic.
    func fetchGenreCards(maxCovers: Int = 4) async throws -> [CollectionCardData] {
        try await self.database.read { db in
            try Self.collectionCards(in: db, column: .genre, maxCovers: maxCovers)
        }
    }

    /// One `CollectionCardData` per distinct composer, same shape and rules as
    /// ``fetchGenreCards(maxCovers:)``. Matches `TrackRepository.allComposers`.
    func fetchComposerCards(maxCovers: Int = 4) async throws -> [CollectionCardData] {
        try await self.database.read { db in
            try Self.collectionCards(in: db, column: .composer, maxCovers: maxCovers)
        }
    }

    /// Albums having at least one non-disabled track in `genre`, distinct and
    /// ordered by title. Tracks with a NULL `album_id` contribute no album (the
    /// join drops them). Backs the genre destination's Albums mode (phase 23-3).
    func fetchAll(genre: String) async throws -> [Album] {
        try await self.database.read { db in
            try Self.albums(in: db, column: .genre, value: genre)
        }
    }

    /// Albums having at least one non-disabled track by `composer`, distinct and
    /// ordered by title. Same rules as ``fetchAll(genre:)``.
    func fetchAll(composer: String) async throws -> [Album] {
        try await self.database.read { db in
            try Self.albums(in: db, column: .composer, value: composer)
        }
    }
}

// MARK: - Shared genre/composer card query

private extension AlbumRepository {
    /// The free-text track column a collection groups on. Fixed literals, never
    /// user input, so interpolating the raw value into SQL is safe.
    enum CollectionColumn: String {
        case genre
        case composer
    }

    /// Builds the card rows for `column`: counts grouped by the column, plus up
    /// to `maxCovers` deterministic cover paths per value. Runs inside a read.
    static func collectionCards(
        in db: GRDB.Database,
        column: CollectionColumn,
        maxCovers: Int
    ) throws -> [CollectionCardData] {
        let col = column.rawValue
        // Counts: distinct albums (NULL album_id ignored by COUNT DISTINCT) and
        // total non-disabled songs, grouped by the value. Mirrors the list's
        // `WHERE <col> IS NOT NULL AND disabled = 0` so the value sets match.
        let countRows = try Row.fetchAll(db, sql: """
            SELECT \(col) AS name,
                   COUNT(DISTINCT album_id) AS album_count,
                   COUNT(*) AS song_count
            FROM tracks
            WHERE \(col) IS NOT NULL AND disabled = 0
            GROUP BY \(col)
        """)
        // Covers: one row per (value, album) with art, newest album first.
        let coverRows = try Row.fetchAll(db, sql: """
            SELECT t.\(col) AS name, al.cover_art_path AS cover_art_path
            FROM tracks t
            JOIN albums al ON al.id = t.album_id
            WHERE t.\(col) IS NOT NULL AND t.disabled = 0 AND al.cover_art_path IS NOT NULL
            GROUP BY t.\(col), al.id
            ORDER BY al.year DESC, al.title
        """)
        var covers: [String: [String]] = [:]
        for row in coverRows {
            guard let name: String = row["name"], let path: String = row["cover_art_path"] else { continue }
            var paths = covers[name, default: []]
            guard paths.count < maxCovers, !paths.contains(path) else { continue }
            paths.append(path)
            covers[name] = paths
        }
        return countRows.compactMap { row in
            guard let name: String = row["name"] else { return nil }
            return CollectionCardData(
                name: name,
                albumCount: row["album_count"] ?? 0,
                songCount: row["song_count"] ?? 0,
                coverArtPaths: covers[name] ?? []
            )
        }
    }

    /// Distinct albums whose non-disabled tracks match `value` on `column`,
    /// ordered by title.
    static func albums(in db: GRDB.Database, column: CollectionColumn, value: String) throws -> [Album] {
        let sql = """
            SELECT DISTINCT al.*
            FROM albums al
            JOIN tracks t ON t.album_id = al.id
            WHERE t.\(column.rawValue) = ? AND t.disabled = 0
            ORDER BY al.title
        """
        let rows = try Row.fetchAll(db, sql: sql, arguments: [value])
        return try rows.map { try Album(row: $0) }
    }
}
