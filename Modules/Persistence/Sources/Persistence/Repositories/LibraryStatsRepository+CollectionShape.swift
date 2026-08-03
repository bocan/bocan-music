import Foundation
import GRDB

// MARK: - LibraryCollectionShapeReport

/// The shape of the collection for the Library Summary window (#373): when
/// the music was made, how deep each artist runs, and the outliers. Framings
/// chosen to surprise: ownership and listening are reported side by side per
/// decade because the gap between them is the interesting bit.
public struct LibraryCollectionShapeReport: Equatable, Sendable {
    /// One release year's track count.
    public struct YearCount: Equatable, Sendable, Identifiable {
        public var id: Int {
            self.year
        }

        public let year: Int
        public let count: Int
    }

    /// One decade's ownership versus listening. `decade` is the leading year
    /// (1990 means the 1990s).
    public struct DecadeShare: Equatable, Sendable, Identifiable {
        public var id: Int {
            self.decade
        }

        public let decade: Int
        public let trackCount: Int
        /// Seconds of music owned from this decade (sum of durations).
        public let ownedSeconds: Double
        /// Seconds actually listened (sum of per-track play time).
        public let playedSeconds: Double
    }

    /// One of the deepest catalogues: an album artist and their album count.
    public struct DeepArtist: Equatable, Sendable, Identifiable {
        public let id: Int64
        public let name: String
        public let albumCount: Int
    }

    /// A duration outlier track.
    public struct ExtremeTrack: Equatable, Sendable, Identifiable {
        public let id: Int64
        public let trackTitle: String
        /// Navigation target for the row, when the track has one.
        public let albumID: Int64?
        public let albumTitle: String?
        public let duration: Double
    }

    /// The longest album by total running time.
    public struct ExtremeAlbum: Equatable, Sendable, Identifiable {
        public let id: Int64
        public let albumTitle: String
        public let albumArtistName: String?
        public let totalSeconds: Double
        public let trackCount: Int
    }

    /// One decade's average album length (albums with at least
    /// ``LibraryStatsRepository/minimumAlbumTracksForLength`` tracks, so
    /// singles and EP stubs don't drag the mean down).
    public struct DecadeAlbumLength: Equatable, Sendable, Identifiable {
        public var id: Int {
            self.decade
        }

        public let decade: Int
        public let averageSeconds: Double
        public let albumCount: Int
    }

    /// Track counts per plausible release year, ascending.
    public let years: [YearCount]
    /// Enabled tracks with no usable year: the honest gap under the histogram.
    public let undatedTrackCount: Int
    /// Ownership versus listening per decade, ascending.
    public let decades: [DecadeShare]

    /// Artists credited on at least one enabled track.
    public let artistCount: Int
    /// The long tail: artists with exactly one enabled track.
    public let singleTrackArtistCount: Int
    /// Album artists with ``LibraryStatsRepository/deepArtistAlbumThreshold``
    /// or more albums.
    public let deepArtistCount: Int
    /// The deepest catalogues, most albums first.
    public let deepestArtists: [DeepArtist]

    public let longestTrack: ExtremeTrack?
    public let shortestTrack: ExtremeTrack?
    public let longestAlbum: ExtremeAlbum?
    /// Average album length per decade, ascending.
    public let albumLengthByDecade: [DecadeAlbumLength]
}

// MARK: - Collection shape queries

/// The Collection Shape detectors (#373), split from the other report slices
/// so each file stays focused.
public extension LibraryStatsRepository {
    /// Album artists with at least this many albums count as a deep catalogue.
    static let deepArtistAlbumThreshold = 10
    /// Albums need at least this many tracks to join the album-length means.
    static let minimumAlbumTracksForLength = 4

    /// Runs every collection-shape query in one read transaction.
    func fetchCollectionShape() async throws -> LibraryCollectionShapeReport {
        // Mirrors the hygiene detector's plausibility bounds so both tabs
        // agree on what a junk year is.
        let maxYear = Calendar.current.component(.year, from: Date()) + 1
        return try await self.database.read { db in
            let depth = try Self.artistDepth(db)
            let extremes = try Self.trackExtremes(db)
            return try LibraryCollectionShapeReport(
                years: Self.yearHistogram(db, maxYear: maxYear),
                undatedTrackCount: Self.undatedCount(db, maxYear: maxYear),
                decades: Self.decadeShares(db, maxYear: maxYear),
                artistCount: depth.artistCount,
                singleTrackArtistCount: depth.singleTrackCount,
                deepArtistCount: depth.deepCount,
                deepestArtists: Self.deepestArtists(db),
                longestTrack: extremes.longest,
                shortestTrack: extremes.shortest,
                longestAlbum: Self.longestAlbum(db),
                albumLengthByDecade: Self.albumLengthByDecade(db, maxYear: maxYear)
            )
        }
    }
}

private extension LibraryStatsRepository {
    /// Same bound as the hygiene detector's `earliestPlausibleYear`.
    static let earliestYear = 1900

    static func yearHistogram(_ db: GRDB.Database, maxYear: Int) throws -> [LibraryCollectionShapeReport.YearCount] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT year, COUNT(*) AS cnt FROM tracks
            WHERE disabled = 0 AND year >= ? AND year <= ?
            GROUP BY year ORDER BY year
            """,
            arguments: [self.earliestYear, maxYear]
        )
        return rows.compactMap { row in
            guard let year: Int = row["year"] else { return nil }
            return LibraryCollectionShapeReport.YearCount(year: year, count: row["cnt"] ?? 0)
        }
    }

    static func undatedCount(_ db: GRDB.Database, maxYear: Int) throws -> Int {
        try Int.fetchOne(
            db,
            sql: """
            SELECT COUNT(*) FROM tracks
            WHERE disabled = 0 AND (year IS NULL OR year < ? OR year > ?)
            """,
            arguments: [self.earliestYear, maxYear]
        ) ?? 0
    }

    static func decadeShares(_ db: GRDB.Database, maxYear: Int) throws -> [LibraryCollectionShapeReport.DecadeShare] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT (year / 10) * 10 AS decade,
                   COUNT(*) AS cnt,
                   COALESCE(SUM(duration), 0) AS owned,
                   COALESCE(SUM(play_duration_total), 0) AS played
            FROM tracks
            WHERE disabled = 0 AND year >= ? AND year <= ?
            GROUP BY decade ORDER BY decade
            """,
            arguments: [self.earliestYear, maxYear]
        )
        return rows.compactMap { row in
            guard let decade: Int = row["decade"] else { return nil }
            return LibraryCollectionShapeReport.DecadeShare(
                decade: decade,
                trackCount: row["cnt"] ?? 0,
                ownedSeconds: row["owned"] ?? 0,
                playedSeconds: row["played"] ?? 0
            )
        }
    }

    struct ArtistDepthCounts {
        let artistCount: Int
        let singleTrackCount: Int
        let deepCount: Int
    }

    static func artistDepth(_ db: GRDB.Database) throws -> ArtistDepthCounts {
        let artistCount = try Int.fetchOne(db, sql: """
            SELECT COUNT(DISTINCT artist_id) FROM tracks
            WHERE disabled = 0 AND artist_id IS NOT NULL
        """) ?? 0
        let singleTrackCount = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM (
                SELECT artist_id FROM tracks
                WHERE disabled = 0 AND artist_id IS NOT NULL
                GROUP BY artist_id HAVING COUNT(*) = 1
            )
        """) ?? 0
        let deepCount = try Int.fetchOne(
            db,
            sql: """
            SELECT COUNT(*) FROM (
                SELECT albums.album_artist_id FROM albums
                WHERE albums.album_artist_id IS NOT NULL
                  AND EXISTS (
                    SELECT 1 FROM tracks
                    WHERE tracks.album_id = albums.id AND tracks.disabled = 0
                  )
                GROUP BY albums.album_artist_id
                HAVING COUNT(*) >= ?
            )
            """,
            arguments: [Self.deepArtistAlbumThreshold]
        ) ?? 0
        return ArtistDepthCounts(
            artistCount: artistCount,
            singleTrackCount: singleTrackCount,
            deepCount: deepCount
        )
    }

    static func deepestArtists(_ db: GRDB.Database) throws -> [LibraryCollectionShapeReport.DeepArtist] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT artists.id AS id, artists.name AS name, COUNT(*) AS album_count
            FROM albums
            JOIN artists ON artists.id = albums.album_artist_id
            WHERE EXISTS (
                SELECT 1 FROM tracks
                WHERE tracks.album_id = albums.id AND tracks.disabled = 0
            )
            GROUP BY albums.album_artist_id
            ORDER BY album_count DESC, artists.name ASC
            LIMIT 5
        """)
        return rows.compactMap { row in
            guard let id: Int64 = row["id"] else { return nil }
            return LibraryCollectionShapeReport.DeepArtist(
                id: id,
                name: row["name"] ?? "",
                albumCount: row["album_count"] ?? 0
            )
        }
    }

    static func trackExtremes(
        _ db: GRDB.Database
    ) throws -> (longest: LibraryCollectionShapeReport.ExtremeTrack?, shortest: LibraryCollectionShapeReport.ExtremeTrack?) {
        try (
            longest: self.extremeTrack(db, order: "DESC"),
            shortest: self.extremeTrack(db, order: "ASC")
        )
    }

    /// `order` is a trusted literal from this file, never user input.
    static func extremeTrack(_ db: GRDB.Database, order: String) throws -> LibraryCollectionShapeReport.ExtremeTrack? {
        let row = try Row.fetchOne(db, sql: """
            SELECT tracks.id AS id,
                   tracks.title AS title,
                   tracks.album_id AS album_id,
                   albums.title AS album_title,
                   tracks.duration AS duration
            FROM tracks
            LEFT JOIN albums ON albums.id = tracks.album_id
            WHERE tracks.disabled = 0 AND tracks.duration > 0
            ORDER BY tracks.duration \(order)
            LIMIT 1
        """)
        guard let row, let id: Int64 = row["id"] else { return nil }
        return LibraryCollectionShapeReport.ExtremeTrack(
            id: id,
            trackTitle: row["title"] ?? "",
            albumID: row["album_id"],
            albumTitle: row["album_title"],
            duration: row["duration"] ?? 0
        )
    }

    static func longestAlbum(_ db: GRDB.Database) throws -> LibraryCollectionShapeReport.ExtremeAlbum? {
        let row = try Row.fetchOne(db, sql: """
            SELECT albums.id AS id,
                   albums.title AS title,
                   artists.name AS artist_name,
                   SUM(tracks.duration) AS total,
                   COUNT(*) AS cnt
            FROM tracks
            JOIN albums ON albums.id = tracks.album_id
            LEFT JOIN artists ON artists.id = albums.album_artist_id
            WHERE tracks.disabled = 0
            GROUP BY tracks.album_id
            ORDER BY total DESC
            LIMIT 1
        """)
        guard let row, let id: Int64 = row["id"] else { return nil }
        return LibraryCollectionShapeReport.ExtremeAlbum(
            id: id,
            albumTitle: row["title"] ?? "",
            albumArtistName: row["artist_name"],
            totalSeconds: row["total"] ?? 0,
            trackCount: row["cnt"] ?? 0
        )
    }

    static func albumLengthByDecade(
        _ db: GRDB.Database,
        maxYear: Int
    ) throws -> [LibraryCollectionShapeReport.DecadeAlbumLength] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT (albums.year / 10) * 10 AS decade,
                   AVG(album_totals.total) AS avg_seconds,
                   COUNT(*) AS album_count
            FROM (
                SELECT album_id, SUM(duration) AS total
                FROM tracks
                WHERE disabled = 0 AND album_id IS NOT NULL
                GROUP BY album_id
                HAVING COUNT(*) >= ?
            ) AS album_totals
            JOIN albums ON albums.id = album_totals.album_id
            WHERE albums.year >= ? AND albums.year <= ?
            GROUP BY decade ORDER BY decade
            """,
            arguments: [
                Self.minimumAlbumTracksForLength,
                self.earliestYear,
                maxYear,
            ]
        )
        return rows.compactMap { row in
            guard let decade: Int = row["decade"] else { return nil }
            return LibraryCollectionShapeReport.DecadeAlbumLength(
                decade: decade,
                averageSeconds: row["avg_seconds"] ?? 0,
                albumCount: row["album_count"] ?? 0
            )
        }
    }
}
