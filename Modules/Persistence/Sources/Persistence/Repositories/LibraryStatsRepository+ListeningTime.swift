import Foundation
import GRDB

// MARK: - LibraryListeningTimeReport

/// The time analytics for the Listening Behaviour tab (#373, phase 25-3):
/// when listening happens, how often new artists arrive, and which artists
/// belong to one month of the year. Every query unions local `play_history`
/// with `imported_listens` (matched or not), so an imported decade counts.
///
/// Timestamps are stored as UTC epoch seconds; the hour/weekday/month
/// buckets here are computed in the machine's current time zone (SQLite's
/// `localtime`, DST-correct per play). Plays scrobbled from another time
/// zone shift by the offset; the UI owns saying so.
public struct LibraryListeningTimeReport: Equatable, Sendable {
    /// Plays in one hour-of-day on one weekday. `weekday` uses SQLite's
    /// `%w` numbering: 0 is Sunday through 6 is Saturday.
    public struct HourWeekdayCount: Equatable, Sendable {
        public let weekday: Int
        public let hour: Int
        public let count: Int
    }

    /// New artists first heard in one calendar month.
    public struct MonthlyDiscovery: Equatable, Sendable {
        public let year: Int
        /// 1...12.
        public let month: Int
        public let newArtists: Int
    }

    /// An artist whose plays pile into a single month of the year.
    public struct SeasonalArtist: Equatable, Sendable, Identifiable {
        /// Name and month together: an exact 50/50 split can qualify twice.
        public var id: String {
            "\(self.name)#\(self.peakMonth)"
        }

        public let name: String
        /// 1...12: the month holding the skew.
        public let peakMonth: Int
        /// Plays landing in `peakMonth`.
        public let peakMonthPlays: Int
        /// All plays for the artist across both sources.
        public let totalPlays: Int

        /// The peak month's share of all plays, 0...1.
        public var share: Double {
            self.totalPlays > 0 ? Double(self.peakMonthPlays) / Double(self.totalPlays) : 0
        }
    }

    /// Plays with usable timestamps across both sources.
    public let totalPlays: Int
    /// Non-empty heatmap cells (at most 7 x 24).
    public let heatmap: [HourWeekdayCount]
    /// First-heard artist counts per month, ascending; empty months absent.
    public let discoveryByMonth: [MonthlyDiscovery]
    /// Strongest skew first, capped at ``LibraryHygieneReport/maxExamples``.
    public let seasonalArtists: [SeasonalArtist]
}

// MARK: - Time analytics queries

/// The time-analytics detectors (#373, phase 25-3), split from the counter
/// analytics so each file stays focused.
public extension LibraryStatsRepository {
    /// Plays an artist needs before a seasonal skew is worth reporting.
    static let seasonalMinimumPlays = 12
    /// Share of all plays one month must hold to count as a skew.
    static let seasonalMinimumShare = 0.5
    /// The skewed month must recur across at least this many distinct years,
    /// or a one-off album binge masquerades as a season.
    static let seasonalMinimumYears = 2

    /// Runs every time-analytics query in one read transaction.
    func fetchListeningTime() async throws -> LibraryListeningTimeReport {
        try await self.database.read { db in
            let cells = try Self.heatmapCells(db)
            return try LibraryListeningTimeReport(
                totalPlays: cells.reduce(0) { $0 + $1.count },
                heatmap: cells,
                discoveryByMonth: Self.discoveryByMonth(db),
                seasonalArtists: Self.seasonalArtists(db)
            )
        }
    }
}

private extension LibraryStatsRepository {
    /// Every play timestamp from both sources; a trusted literal fragment.
    static let allPlays = """
        SELECT played_at FROM play_history
        UNION ALL
        SELECT played_at FROM imported_listens
    """

    /// Artist identity per play across both sources: the normalised key
    /// merges "wade bowen" between a library credit and a scrobble string,
    /// while `display` keeps a presentable casing.
    static let artistPlays = """
        SELECT lower(trim(artists.name)) AS artist,
               artists.name AS display,
               play_history.played_at AS played_at
        FROM play_history
        JOIN tracks ON tracks.id = play_history.track_id
        JOIN artists ON artists.id = tracks.artist_id
        UNION ALL
        SELECT lower(trim(artist)), artist, played_at FROM imported_listens
    """

    static func heatmapCells(_ db: GRDB.Database) throws -> [LibraryListeningTimeReport.HourWeekdayCount] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT CAST(strftime('%w', played_at, 'unixepoch', 'localtime') AS INTEGER) AS weekday,
                   CAST(strftime('%H', played_at, 'unixepoch', 'localtime') AS INTEGER) AS hour,
                   COUNT(*) AS cnt
            FROM (\(self.allPlays))
            GROUP BY weekday, hour
            ORDER BY weekday, hour
        """)
        return rows.compactMap { row in
            guard let weekday: Int = row["weekday"], let hour: Int = row["hour"] else { return nil }
            return LibraryListeningTimeReport.HourWeekdayCount(
                weekday: weekday,
                hour: hour,
                count: row["cnt"] ?? 0
            )
        }
    }

    static func discoveryByMonth(_ db: GRDB.Database) throws -> [LibraryListeningTimeReport.MonthlyDiscovery] {
        let rows = try Row.fetchAll(db, sql: """
            WITH first_seen AS (
                SELECT artist, MIN(played_at) AS first_at
                FROM (\(self.artistPlays))
                GROUP BY artist
            )
            SELECT CAST(strftime('%Y', first_at, 'unixepoch', 'localtime') AS INTEGER) AS year,
                   CAST(strftime('%m', first_at, 'unixepoch', 'localtime') AS INTEGER) AS month,
                   COUNT(*) AS cnt
            FROM first_seen
            GROUP BY year, month
            ORDER BY year, month
        """)
        return rows.compactMap { row in
            guard let year: Int = row["year"], let month: Int = row["month"] else { return nil }
            return LibraryListeningTimeReport.MonthlyDiscovery(
                year: year,
                month: month,
                newArtists: row["cnt"] ?? 0
            )
        }
    }

    static func seasonalArtists(_ db: GRDB.Database) throws -> [LibraryListeningTimeReport.SeasonalArtist] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            WITH plays AS (\(self.artistPlays)),
            monthly AS (
                SELECT artist,
                       MAX(display) AS display,
                       CAST(strftime('%m', played_at, 'unixepoch', 'localtime') AS INTEGER) AS month,
                       COUNT(*) AS cnt,
                       COUNT(DISTINCT strftime('%Y', played_at, 'unixepoch', 'localtime')) AS years
                FROM plays
                GROUP BY artist, month
            ),
            totals AS (
                SELECT artist, SUM(cnt) AS total FROM monthly GROUP BY artist
            )
            SELECT monthly.display AS display,
                   monthly.month AS month,
                   monthly.cnt AS cnt,
                   totals.total AS total
            FROM monthly
            JOIN totals ON totals.artist = monthly.artist
            WHERE totals.total >= ?
              AND monthly.years >= ?
              AND CAST(monthly.cnt AS REAL) / totals.total >= ?
            ORDER BY CAST(monthly.cnt AS REAL) / totals.total DESC, totals.total DESC
            LIMIT \(LibraryHygieneReport.maxExamples)
            """,
            arguments: [
                Self.seasonalMinimumPlays,
                Self.seasonalMinimumYears,
                Self.seasonalMinimumShare,
            ]
        )
        return rows.compactMap { row in
            guard let month: Int = row["month"] else { return nil }
            return LibraryListeningTimeReport.SeasonalArtist(
                name: row["display"] ?? "",
                peakMonth: month,
                peakMonthPlays: row["cnt"] ?? 0,
                totalPlays: row["total"] ?? 0
            )
        }
    }
}
