import Foundation
import GRDB

// MARK: - LibraryListeningReport

/// The counter analytics for the Listening Behaviour tab (#373, phase 25-2).
///
/// "Lifetime" figures combine local plays with matched imported listens;
/// `play_history`'s counting rule (a play means more than half consumed)
/// already gives skip rate its teeth. Structured data only; prose is the UI
/// layer's job.
public struct LibraryListeningReport: Equatable, Sendable {
    /// A track skipped more often than played: the delete-candidates list.
    public struct SkipCandidate: Equatable, Sendable, Identifiable {
        public let id: Int64
        public let trackTitle: String
        /// Navigation target for the row, when the track has one.
        public let albumID: Int64?
        public let albumTitle: String?
        public let playCount: Int
        public let skipCount: Int
        /// Average bail-out point in seconds, when skips recorded one.
        public let averageBailSeconds: Double?

        /// Skips as a share of all attempts, 0...1.
        public var skipRate: Double {
            let attempts = self.playCount + self.skipCount
            return attempts > 0 ? Double(self.skipCount) / Double(attempts) : 0
        }
    }

    /// High lifetime plays, silent for two years: the rediscovery list.
    public struct DormantFavourite: Equatable, Sendable, Identifiable {
        public let id: Int64
        public let trackTitle: String
        /// Navigation target for the row, when the track has one.
        public let albumID: Int64?
        public let albumTitle: String?
        /// Local plays plus matched imported listens.
        public let lifetimePlays: Int
        /// Unix timestamp of the most recent play from either source.
        public let lastPlayedAt: Int64
    }

    /// An album never played past its leading tracks.
    public struct AbandonedAlbum: Equatable, Sendable, Identifiable {
        public let id: Int64
        public let albumTitle: String
        public let albumArtistName: String?
        /// Highest track number ever played.
        public let playedThroughTrack: Int
        public let trackCount: Int
    }

    /// Enabled tracks in the library.
    public let trackCount: Int
    /// Tracks with at least one lifetime play.
    public let playedTrackCount: Int
    /// Gini coefficient over lifetime play counts across every enabled
    /// track: 0 means perfectly even rotation, 1 means one song took every
    /// play. `nil` until anything has been played.
    public let giniCoefficient: Double?

    public let skipCandidateCount: Int
    /// Worst skip rate first, capped at ``LibraryHygieneReport/maxExamples``.
    public let skipCandidates: [SkipCandidate]

    public let dormantFavouriteCount: Int
    /// Most lifetime plays first, capped at ``LibraryHygieneReport/maxExamples``.
    public let dormantFavourites: [DormantFavourite]

    public let abandonedAlbumCount: Int
    /// Longest abandoned albums first, capped at ``LibraryHygieneReport/maxExamples``.
    public let abandonedAlbums: [AbandonedAlbum]
}

// MARK: - Listening behaviour queries

/// The Listening Behaviour detectors (#373, phase 25-2), split from the other
/// report slices so each file stays focused.
public extension LibraryStatsRepository {
    /// Skips needed before a track can be a delete candidate at all.
    static let skipCandidateMinimumSkips = 3
    /// Lifetime plays needed before silence makes a track a dormant favourite.
    static let dormantMinimumLifetimePlays = 10
    /// Silence window for dormancy: 24 months, as seconds.
    static let dormantCutoffSeconds: Int64 = 63_072_000
    /// Albums need at least this many tracks before abandonment means much.
    static let abandonedAlbumMinimumTracks = 6
    /// "Never got past the singles": highest played track number allowed.
    static let abandonedLeadingTracks = 3

    /// Runs every listening-behaviour query in one read transaction.
    func fetchListeningBehaviour() async throws -> LibraryListeningReport {
        let cutoff = Int64(Date().timeIntervalSince1970) - Self.dormantCutoffSeconds
        return try await self.database.read { db in
            let lifetimes = try Self.lifetimePlayCounts(db)
            let skips = try Self.skipCandidates(db)
            let dormant = try Self.dormantFavourites(db, cutoff: cutoff)
            let abandoned = try Self.abandonedAlbums(db)
            return LibraryListeningReport(
                trackCount: lifetimes.count,
                playedTrackCount: lifetimes.count { $0 > 0 },
                giniCoefficient: Self.gini(lifetimes),
                skipCandidateCount: skips.total,
                skipCandidates: skips.examples,
                dormantFavouriteCount: dormant.total,
                dormantFavourites: dormant.examples,
                abandonedAlbumCount: abandoned.total,
                abandonedAlbums: abandoned.examples
            )
        }
    }

    /// Gini coefficient over a play-count distribution, `nil` when nothing
    /// has been played. Exposed internally for direct testing.
    internal static func gini(_ counts: [Int]) -> Double? {
        let sorted = counts.sorted()
        let population = sorted.count
        let total = sorted.reduce(0, +)
        guard population > 0, total > 0 else { return nil }
        var weighted = 0.0
        for (index, plays) in sorted.enumerated() {
            weighted += Double(index + 1) * Double(plays)
        }
        return (2 * weighted) / (Double(population) * Double(total)) - Double(population + 1) / Double(population)
    }
}

private extension LibraryStatsRepository {
    /// Per-track matched-import aggregates, joined as `imports`.
    /// A trusted literal fragment shared by the lifetime-aware queries.
    static let importsJoin = """
        LEFT JOIN (
            SELECT track_id, COUNT(*) AS import_count, MAX(played_at) AS import_last
            FROM imported_listens
            WHERE track_id IS NOT NULL
            GROUP BY track_id
        ) AS imports ON imports.track_id = tracks.id
    """

    static func lifetimePlayCounts(_ db: GRDB.Database) throws -> [Int] {
        try Int.fetchAll(db, sql: """
            SELECT tracks.play_count + COALESCE(imports.import_count, 0)
            FROM tracks
            \(self.importsJoin)
            WHERE tracks.disabled = 0
        """)
    }

    static func skipCandidates(
        _ db: GRDB.Database
    ) throws -> (total: Int, examples: [LibraryListeningReport.SkipCandidate]) {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT tracks.id AS id,
                   tracks.title AS title,
                   tracks.album_id AS album_id,
                   albums.title AS album_title,
                   tracks.play_count AS plays,
                   tracks.skip_count AS skips,
                   tracks.skip_after_seconds AS bail
            FROM tracks
            LEFT JOIN albums ON albums.id = tracks.album_id
            WHERE tracks.disabled = 0
              AND tracks.skip_count >= ?
              AND tracks.skip_count > tracks.play_count
            ORDER BY CAST(tracks.skip_count AS REAL) / (tracks.skip_count + tracks.play_count) DESC,
                     tracks.skip_count DESC
            """,
            arguments: [Self.skipCandidateMinimumSkips]
        )
        let examples: [LibraryListeningReport.SkipCandidate] = rows
            .prefix(LibraryHygieneReport.maxExamples)
            .compactMap { row in
                guard let id: Int64 = row["id"] else { return nil }
                return LibraryListeningReport.SkipCandidate(
                    id: id,
                    trackTitle: row["title"] ?? "",
                    albumID: row["album_id"],
                    albumTitle: row["album_title"],
                    playCount: row["plays"] ?? 0,
                    skipCount: row["skips"] ?? 0,
                    averageBailSeconds: row["bail"]
                )
            }
        return (rows.count, examples)
    }

    static func dormantFavourites(
        _ db: GRDB.Database,
        cutoff: Int64
    ) throws -> (total: Int, examples: [LibraryListeningReport.DormantFavourite]) {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT tracks.id AS id,
                   tracks.title AS title,
                   tracks.album_id AS album_id,
                   albums.title AS album_title,
                   tracks.play_count + COALESCE(imports.import_count, 0) AS lifetime,
                   MAX(COALESCE(tracks.last_played_at, 0), COALESCE(imports.import_last, 0)) AS last_any
            FROM tracks
            \(self.importsJoin)
            LEFT JOIN albums ON albums.id = tracks.album_id
            WHERE tracks.disabled = 0
              AND tracks.play_count + COALESCE(imports.import_count, 0) >= ?
              AND MAX(COALESCE(tracks.last_played_at, 0), COALESCE(imports.import_last, 0)) > 0
              AND MAX(COALESCE(tracks.last_played_at, 0), COALESCE(imports.import_last, 0)) < ?
            ORDER BY lifetime DESC, last_any ASC
            """,
            arguments: [Self.dormantMinimumLifetimePlays, cutoff]
        )
        let examples: [LibraryListeningReport.DormantFavourite] = rows
            .prefix(LibraryHygieneReport.maxExamples)
            .compactMap { row in
                guard let id: Int64 = row["id"] else { return nil }
                return LibraryListeningReport.DormantFavourite(
                    id: id,
                    trackTitle: row["title"] ?? "",
                    albumID: row["album_id"],
                    albumTitle: row["album_title"],
                    lifetimePlays: row["lifetime"] ?? 0,
                    lastPlayedAt: row["last_any"] ?? 0
                )
            }
        return (rows.count, examples)
    }

    /// Single-disc albums only: "played through track N" has no honest
    /// meaning across discs, and abandoned albums are rarely box sets.
    static func abandonedAlbums(
        _ db: GRDB.Database
    ) throws -> (total: Int, examples: [LibraryListeningReport.AbandonedAlbum]) {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT albums.id AS id,
                   albums.title AS title,
                   artists.name AS artist_name,
                   MAX(CASE WHEN tracks.play_count > 0 OR imports.track_id IS NOT NULL
                            THEN tracks.track_number END) AS played_through,
                   COUNT(*) AS track_count
            FROM tracks
            LEFT JOIN (
                SELECT DISTINCT track_id FROM imported_listens WHERE track_id IS NOT NULL
            ) AS imports ON imports.track_id = tracks.id
            JOIN albums ON albums.id = tracks.album_id
            LEFT JOIN artists ON artists.id = albums.album_artist_id
            WHERE tracks.disabled = 0 AND tracks.track_number IS NOT NULL
            GROUP BY tracks.album_id
            HAVING COUNT(*) >= ?
               AND MAX(COALESCE(tracks.disc_number, 1)) <= 1
               AND played_through BETWEEN 1 AND ?
               AND MAX(tracks.track_number) > ?
            ORDER BY track_count DESC, albums.title ASC
            """,
            arguments: [
                Self.abandonedAlbumMinimumTracks,
                Self.abandonedLeadingTracks,
                Self.abandonedLeadingTracks,
            ]
        )
        let examples: [LibraryListeningReport.AbandonedAlbum] = rows
            .prefix(LibraryHygieneReport.maxExamples)
            .compactMap { row in
                guard let id: Int64 = row["id"] else { return nil }
                return LibraryListeningReport.AbandonedAlbum(
                    id: id,
                    albumTitle: row["title"] ?? "",
                    albumArtistName: row["artist_name"],
                    playedThroughTrack: row["played_through"] ?? 0,
                    trackCount: row["track_count"] ?? 0
                )
            }
        return (rows.count, examples)
    }
}
