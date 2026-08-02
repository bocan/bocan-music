import Foundation
import GRDB

// MARK: - LibraryHygieneReport

/// Library-hygiene findings for the Library Summary window (#373): tagging
/// and file problems a user can actually act on. All values are structured
/// data; user-facing prose is the UI layer's job (localization boundary).
public struct LibraryHygieneReport: Equatable, Sendable {
    /// An album whose enabled tracks skip one or more track numbers.
    public struct TrackGapAlbum: Equatable, Sendable, Identifiable {
        public let id: Int64
        public let albumTitle: String
        public let albumArtistName: String?
        /// Missing positions across all discs, ascending, capped by
        /// ``LibraryHygieneReport/maxExamples``.
        public let missingTrackNumbers: [Int]
    }

    /// A track whose year is implausible or disagrees with its album's year.
    public struct SuspiciousYearTrack: Equatable, Sendable, Identifiable {
        public let id: Int64
        public let trackTitle: String
        public let albumTitle: String?
        public let year: Int
        /// The album's year when the problem is a disagreement, else `nil`.
        public let albumYear: Int?
    }

    /// A normalized album title that exists as several album rows with
    /// different album artists, at least one of them a one-or-two-track
    /// shard: the classic exploded-album symptom. Same-titled albums by
    /// genuinely different artists (every variant substantial) are not
    /// flagged.
    public struct SplitAlbumGroup: Equatable, Sendable, Identifiable {
        public var id: String {
            self.title
        }

        public let title: String
        public let variantCount: Int
        /// How many variants have two or fewer enabled tracks.
        public let shardCount: Int
    }

    /// A track row whose file has vanished (the scanner marked it disabled).
    public struct MissingFileTrack: Equatable, Sendable, Identifiable {
        public let id: Int64
        public let trackTitle: String
        public let fileURL: String
    }

    /// Offender lists are capped at this many rows; the `*Count` fields carry
    /// the uncapped totals.
    public static let maxExamples = 50

    /// Albums with at least one enabled track (the completeness denominator).
    public let albumCount: Int
    public let albumsMissingArtwork: Int
    public let albumsMissingYear: Int
    public let albumsMissingMusicBrainzID: Int

    public let trackGapAlbumCount: Int
    public let trackGapAlbums: [TrackGapAlbum]

    public let suspiciousYearCount: Int
    public let suspiciousYearTracks: [SuspiciousYearTrack]

    public let splitAlbumCount: Int
    public let splitAlbums: [SplitAlbumGroup]

    public let missingFileCount: Int
    public let missingFiles: [MissingFileTrack]

    /// True when every detector came back clean.
    public var isClean: Bool {
        self.albumsMissingArtwork == 0 && self.albumsMissingYear == 0
            && self.albumsMissingMusicBrainzID == 0 && self.trackGapAlbumCount == 0
            && self.suspiciousYearCount == 0 && self.splitAlbumCount == 0
            && self.missingFileCount == 0
    }
}

// MARK: - Hygiene queries

/// The Library Hygiene detectors (#373), split from the summary counts so
/// each file stays focused.
public extension LibraryStatsRepository {
    /// Runs every hygiene detector in one read transaction. Row scans happen
    /// in SQL; the gap and split grouping runs in Swift over compact tuples,
    /// which stays cheap even for very large libraries.
    func fetchHygiene() async throws -> LibraryHygieneReport {
        try await self.database.read { db in
            let completeness = try Self.completeness(db)
            let gaps = try Self.trackGaps(db)
            let years = try Self.suspiciousYears(db)
            let splits = try Self.splitAlbums(db)
            let missing = try Self.missingFiles(db)
            return LibraryHygieneReport(
                albumCount: completeness.total,
                albumsMissingArtwork: completeness.noArt,
                albumsMissingYear: completeness.noYear,
                albumsMissingMusicBrainzID: completeness.noMBID,
                trackGapAlbumCount: gaps.total,
                trackGapAlbums: gaps.examples,
                suspiciousYearCount: years.total,
                suspiciousYearTracks: years.examples,
                splitAlbumCount: splits.total,
                splitAlbums: splits.examples,
                missingFileCount: missing.total,
                missingFiles: missing.examples
            )
        }
    }
}

private extension LibraryStatsRepository {
    /// Years earlier than this are treated as tagging junk (0, 190, 1900
    /// placeholders); commercial recordings barely predate it.
    static let earliestPlausibleYear = 1900

    struct CompletenessCounts {
        let total: Int
        let noArt: Int
        let noYear: Int
        let noMBID: Int
    }

    static func completeness(_ db: GRDB.Database) throws -> CompletenessCounts {
        let row = try Row.fetchOne(db, sql: """
            SELECT COUNT(*) AS total,
                   COALESCE(SUM(cover_art_hash IS NULL AND cover_art_path IS NULL), 0) AS no_art,
                   COALESCE(SUM(year IS NULL), 0) AS no_year,
                   COALESCE(SUM(musicbrainz_release_id IS NULL), 0) AS no_mbid
            FROM albums
            WHERE EXISTS (
                SELECT 1 FROM tracks
                WHERE tracks.album_id = albums.id AND tracks.disabled = 0
            )
        """)
        return CompletenessCounts(
            total: row?["total"] ?? 0,
            noArt: row?["no_art"] ?? 0,
            noYear: row?["no_year"] ?? 0,
            noMBID: row?["no_mbid"] ?? 0
        )
    }

    static func trackGaps(_ db: GRDB.Database) throws -> (total: Int, examples: [LibraryHygieneReport.TrackGapAlbum]) {
        let rows = try Row.fetchAll(db, sql: """
            SELECT tracks.album_id AS album_id,
                   COALESCE(tracks.disc_number, 1) AS disc,
                   tracks.track_number AS n,
                   albums.title AS album_title,
                   artists.name AS artist_name
            FROM tracks
            JOIN albums ON albums.id = tracks.album_id
            LEFT JOIN artists ON artists.id = albums.album_artist_id
            WHERE tracks.disabled = 0 AND tracks.track_number IS NOT NULL
        """)

        struct AlbumAccumulator {
            var title = ""
            var artist: String?
            var numbersByDisc: [Int: Set<Int>] = [:]
        }
        var albums: [Int64: AlbumAccumulator] = [:]
        for row in rows {
            guard let albumID: Int64 = row["album_id"], let n: Int = row["n"], n > 0 else { continue }
            let disc: Int = row["disc"] ?? 1
            var acc = albums[albumID] ?? AlbumAccumulator()
            acc.title = row["album_title"] ?? ""
            acc.artist = row["artist_name"]
            acc.numbersByDisc[disc, default: []].insert(n)
            albums[albumID] = acc
        }

        var offenders: [LibraryHygieneReport.TrackGapAlbum] = []
        for (albumID, acc) in albums {
            let totalTracks = acc.numbersByDisc.values.reduce(0) { $0 + $1.count }
            guard totalTracks >= 2 else { continue } // singles aren't gaps
            var missing: [Int] = []
            for (_, numbers) in acc.numbersByDisc.sorted(by: { $0.key < $1.key }) {
                guard let top = numbers.max() else { continue }
                missing.append(contentsOf: (1 ... top).filter { !numbers.contains($0) })
            }
            guard !missing.isEmpty else { continue }
            offenders.append(LibraryHygieneReport.TrackGapAlbum(
                id: albumID,
                albumTitle: acc.title,
                albumArtistName: acc.artist,
                missingTrackNumbers: Array(missing.prefix(LibraryHygieneReport.maxExamples))
            ))
        }
        offenders.sort {
            ($0.missingTrackNumbers.count, $0.albumTitle) > ($1.missingTrackNumbers.count, $1.albumTitle)
        }
        return (offenders.count, Array(offenders.prefix(LibraryHygieneReport.maxExamples)))
    }

    static func suspiciousYears(_ db: GRDB.Database) throws -> (total: Int, examples: [LibraryHygieneReport.SuspiciousYearTrack]) {
        let currentYear = Calendar.current.component(.year, from: Date())
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT tracks.id AS id,
                   tracks.title AS title,
                   tracks.year AS year,
                   albums.title AS album_title,
                   albums.year AS album_year
            FROM tracks
            LEFT JOIN albums ON albums.id = tracks.album_id
            WHERE tracks.disabled = 0 AND tracks.year IS NOT NULL
              AND (tracks.year < ? OR tracks.year > ?
                   OR (albums.year IS NOT NULL AND tracks.year <> albums.year))
            ORDER BY tracks.year ASC, tracks.title ASC
            """,
            arguments: [Self.earliestPlausibleYear, currentYear + 1]
        )

        var examples: [LibraryHygieneReport.SuspiciousYearTrack] = []
        for row in rows.prefix(LibraryHygieneReport.maxExamples) {
            guard let id: Int64 = row["id"], let year: Int = row["year"] else { continue }
            let albumYear: Int? = row["album_year"]
            examples.append(LibraryHygieneReport.SuspiciousYearTrack(
                id: id,
                trackTitle: row["title"] ?? "",
                albumTitle: row["album_title"],
                year: year,
                albumYear: albumYear == year ? nil : albumYear
            ))
        }
        return (rows.count, examples)
    }

    static func splitAlbums(_ db: GRDB.Database) throws -> (total: Int, examples: [LibraryHygieneReport.SplitAlbumGroup]) {
        let rows = try Row.fetchAll(db, sql: """
            SELECT albums.id AS id,
                   albums.title AS title,
                   albums.album_artist_id AS artist_id,
                   COUNT(tracks.id) AS track_count
            FROM albums
            JOIN tracks ON tracks.album_id = albums.id AND tracks.disabled = 0
            GROUP BY albums.id
        """)

        struct Variant {
            let artistID: Int64?
            let trackCount: Int
        }
        var groups: [String: (display: String, variants: [Variant])] = [:]
        for row in rows {
            guard let title: String = row["title"], !title.isEmpty else { continue }
            let key = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let variant = Variant(artistID: row["artist_id"], trackCount: row["track_count"] ?? 0)
            groups[key, default: (title, [])].variants.append(variant)
        }

        var offenders: [LibraryHygieneReport.SplitAlbumGroup] = []
        for (_, group) in groups {
            guard group.variants.count >= 2 else { continue }
            let distinctArtists = Set(group.variants.map { $0.artistID ?? -1 })
            guard distinctArtists.count >= 2 else { continue }
            // Same-titled albums by genuinely different artists are all
            // substantial; an exploded album leaves one-or-two-track shards.
            let shards = group.variants.count { $0.trackCount <= 2 }
            guard shards >= 1 else { continue }
            offenders.append(LibraryHygieneReport.SplitAlbumGroup(
                title: group.display,
                variantCount: group.variants.count,
                shardCount: shards
            ))
        }
        offenders.sort { ($0.variantCount, $0.title) > ($1.variantCount, $1.title) }
        return (offenders.count, Array(offenders.prefix(LibraryHygieneReport.maxExamples)))
    }

    static func missingFiles(_ db: GRDB.Database) throws -> (total: Int, examples: [LibraryHygieneReport.MissingFileTrack]) {
        let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks WHERE disabled = 1") ?? 0
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT id, title, file_url FROM tracks
            WHERE disabled = 1
            ORDER BY title ASC
            LIMIT ?
            """,
            arguments: [LibraryHygieneReport.maxExamples]
        )
        let examples: [LibraryHygieneReport.MissingFileTrack] = rows.compactMap { row in
            guard let id: Int64 = row["id"] else { return nil }
            return LibraryHygieneReport.MissingFileTrack(
                id: id,
                trackTitle: row["title"] ?? "",
                fileURL: row["file_url"] ?? ""
            )
        }
        return (total, examples)
    }
}
