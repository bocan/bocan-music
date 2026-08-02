import Foundation
import GRDB

// MARK: - LibraryAudioQualityReport

/// Audio-quality and provenance figures for the Library Summary window
/// (#373): what the library is made of, and the tracks worth a second look.
/// Structured data only; user-facing prose is the UI layer's job.
public struct LibraryAudioQualityReport: Equatable, Sendable {
    /// One codec's share of the library.
    public struct FormatSlice: Equatable, Sendable, Identifiable {
        public var id: String {
            self.format
        }

        /// Lowercased container/codec name as scanned (`flac`, `mp3`, ...).
        public let format: String
        public let count: Int
        public let bytes: Int64
    }

    /// One discrete value's share (a sample rate, bit depth, or bitrate).
    public struct ValueSlice: Equatable, Sendable, Identifiable {
        public var id: Int {
            self.value
        }

        public let value: Int
        public let count: Int
    }

    /// An album whose enabled tracks span more than one file format.
    public struct MixedFormatAlbum: Equatable, Sendable, Identifiable {
        public let id: Int64
        public let albumTitle: String
        public let albumArtistName: String?
        /// Distinct lowercased formats present, alphabetical.
        public let formats: [String]
    }

    /// A track whose stored EBU R128 true peak exceeds full scale.
    public struct TruePeakOverTrack: Equatable, Sendable, Identifiable {
        public let id: Int64
        public let trackTitle: String
        /// Navigation target for the offender row, when the track has one.
        public let albumID: Int64?
        public let albumTitle: String?
        /// Linear true peak (1.0 == 0 dBTP), always greater than 1 here.
        public let truePeakLinear: Double
    }

    public let losslessCount: Int
    public let lossyCount: Int
    /// Tracks the sniffer could not classify (`is_lossless` NULL).
    public let unknownCount: Int
    public let losslessBytes: Int64
    public let lossyBytes: Int64
    public let unknownBytes: Int64

    /// Every format present, largest count first.
    public let formats: [FormatSlice]
    /// Sample rates in Hz, largest count first.
    public let sampleRates: [ValueSlice]
    /// Bit depths, largest count first.
    public let bitDepths: [ValueSlice]
    /// Bitrates in kbps across lossy tracks only, largest count first,
    /// capped at ``LibraryHygieneReport/maxExamples``.
    public let lossyBitrates: [ValueSlice]

    public let mixedFormatAlbumCount: Int
    public let mixedFormatAlbums: [MixedFormatAlbum]

    public let truePeakOverCount: Int
    public let truePeakOvers: [TruePeakOverTrack]
    /// Enabled tracks with no stored ReplayGain true peak: the honest
    /// denominator gap for the overs figure.
    public let unanalysedTrackCount: Int
}

// MARK: - Audio quality queries

/// The Audio Quality detectors (#373), split from the summary counts so each
/// file stays focused.
public extension LibraryStatsRepository {
    /// Runs every audio-quality query in one read transaction.
    func fetchAudioQuality() async throws -> LibraryAudioQualityReport {
        try await self.database.read { db in
            let lossless = try Self.losslessSplit(db)
            let mixed = try Self.mixedFormatAlbums(db)
            let overs = try Self.truePeakOvers(db)
            return try LibraryAudioQualityReport(
                losslessCount: lossless.losslessCount,
                lossyCount: lossless.lossyCount,
                unknownCount: lossless.unknownCount,
                losslessBytes: lossless.losslessBytes,
                lossyBytes: lossless.lossyBytes,
                unknownBytes: lossless.unknownBytes,
                formats: Self.formatSlices(db),
                sampleRates: Self.valueSlices(db, column: "sample_rate", where: "1 = 1"),
                bitDepths: Self.valueSlices(db, column: "bit_depth", where: "1 = 1"),
                lossyBitrates: Self.valueSlices(db, column: "bitrate", where: "is_lossless = 0"),
                mixedFormatAlbumCount: mixed.total,
                mixedFormatAlbums: mixed.examples,
                truePeakOverCount: overs.total,
                truePeakOvers: overs.examples,
                unanalysedTrackCount: Self.unanalysedCount(db)
            )
        }
    }
}

private extension LibraryStatsRepository {
    struct LosslessSplit {
        let losslessCount: Int
        let lossyCount: Int
        let unknownCount: Int
        let losslessBytes: Int64
        let lossyBytes: Int64
        let unknownBytes: Int64
    }

    static func losslessSplit(_ db: GRDB.Database) throws -> LosslessSplit {
        let row = try Row.fetchOne(db, sql: """
            SELECT COALESCE(SUM(is_lossless = 1), 0) AS lc,
                   COALESCE(SUM(is_lossless = 0), 0) AS yc,
                   COALESCE(SUM(is_lossless IS NULL), 0) AS uc,
                   COALESCE(SUM(CASE WHEN is_lossless = 1 THEN file_size ELSE 0 END), 0) AS lb,
                   COALESCE(SUM(CASE WHEN is_lossless = 0 THEN file_size ELSE 0 END), 0) AS yb,
                   COALESCE(SUM(CASE WHEN is_lossless IS NULL THEN file_size ELSE 0 END), 0) AS ub
            FROM tracks WHERE disabled = 0
        """)
        return LosslessSplit(
            losslessCount: row?["lc"] ?? 0,
            lossyCount: row?["yc"] ?? 0,
            unknownCount: row?["uc"] ?? 0,
            losslessBytes: row?["lb"] ?? 0,
            lossyBytes: row?["yb"] ?? 0,
            unknownBytes: row?["ub"] ?? 0
        )
    }

    static func formatSlices(_ db: GRDB.Database) throws -> [LibraryAudioQualityReport.FormatSlice] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT LOWER(file_format) AS fmt,
                   COUNT(*) AS cnt,
                   COALESCE(SUM(file_size), 0) AS bytes
            FROM tracks WHERE disabled = 0
            GROUP BY LOWER(file_format)
            ORDER BY cnt DESC, fmt ASC
        """)
        return rows.compactMap { row in
            guard let fmt: String = row["fmt"], !fmt.isEmpty else { return nil }
            return LibraryAudioQualityReport.FormatSlice(
                format: fmt,
                count: row["cnt"] ?? 0,
                bytes: row["bytes"] ?? 0
            )
        }
    }

    /// Distribution of a discrete integer column over enabled tracks.
    /// `where` is a trusted literal from this file, never user input.
    static func valueSlices(
        _ db: GRDB.Database,
        column: String,
        where condition: String
    ) throws -> [LibraryAudioQualityReport.ValueSlice] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT \(column) AS v, COUNT(*) AS cnt
            FROM tracks
            WHERE disabled = 0 AND \(column) IS NOT NULL AND \(condition)
            GROUP BY \(column)
            ORDER BY cnt DESC, v DESC
            LIMIT \(LibraryHygieneReport.maxExamples)
        """)
        return rows.compactMap { row in
            guard let value: Int = row["v"] else { return nil }
            return LibraryAudioQualityReport.ValueSlice(value: value, count: row["cnt"] ?? 0)
        }
    }

    static func mixedFormatAlbums(
        _ db: GRDB.Database
    ) throws -> (total: Int, examples: [LibraryAudioQualityReport.MixedFormatAlbum]) {
        let rows = try Row.fetchAll(db, sql: """
            SELECT albums.id AS id,
                   albums.title AS title,
                   artists.name AS artist_name,
                   COUNT(DISTINCT LOWER(tracks.file_format)) AS fmt_count,
                   GROUP_CONCAT(DISTINCT LOWER(tracks.file_format)) AS fmts
            FROM albums
            JOIN tracks ON tracks.album_id = albums.id AND tracks.disabled = 0
            LEFT JOIN artists ON artists.id = albums.album_artist_id
            GROUP BY albums.id
            HAVING fmt_count > 1
            ORDER BY fmt_count DESC, albums.title ASC
        """)
        let examples: [LibraryAudioQualityReport.MixedFormatAlbum] = rows
            .prefix(LibraryHygieneReport.maxExamples)
            .compactMap { row in
                guard let id: Int64 = row["id"] else { return nil }
                let fmts: String = row["fmts"] ?? ""
                return LibraryAudioQualityReport.MixedFormatAlbum(
                    id: id,
                    albumTitle: row["title"] ?? "",
                    albumArtistName: row["artist_name"],
                    formats: fmts.split(separator: ",").map(String.init).sorted()
                )
            }
        return (rows.count, examples)
    }

    static func truePeakOvers(
        _ db: GRDB.Database
    ) throws -> (total: Int, examples: [LibraryAudioQualityReport.TruePeakOverTrack]) {
        let total = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM tracks
            WHERE disabled = 0 AND replaygain_track_peak > 1.0
        """) ?? 0
        let rows = try Row.fetchAll(db, sql: """
            SELECT tracks.id AS id,
                   tracks.title AS title,
                   tracks.album_id AS album_id,
                   albums.title AS album_title,
                   tracks.replaygain_track_peak AS peak
            FROM tracks
            LEFT JOIN albums ON albums.id = tracks.album_id
            WHERE tracks.disabled = 0 AND tracks.replaygain_track_peak > 1.0
            ORDER BY tracks.replaygain_track_peak DESC
            LIMIT \(LibraryHygieneReport.maxExamples)
        """)
        let examples: [LibraryAudioQualityReport.TruePeakOverTrack] = rows.compactMap { row in
            guard let id: Int64 = row["id"], let peak: Double = row["peak"] else { return nil }
            return LibraryAudioQualityReport.TruePeakOverTrack(
                id: id,
                trackTitle: row["title"] ?? "",
                albumID: row["album_id"],
                albumTitle: row["album_title"],
                truePeakLinear: peak
            )
        }
        return (total, examples)
    }

    static func unanalysedCount(_ db: GRDB.Database) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM tracks
            WHERE disabled = 0 AND replaygain_track_peak IS NULL
        """) ?? 0
    }
}
