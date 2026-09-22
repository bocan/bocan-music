import Foundation
import GRDB
import Observability

/// Reads the listening record back as a list, newest first (ADR-094).
///
/// Two sources, one shape: `play_history`, written by `PlayHistoryRecorder`,
/// and the rows of `imported_listens` that the re-match pass has linked to
/// a library song. Unmatched imported listens are not listed; they have
/// text but no song, and stay in the Listening Behaviour statistics. This
/// repository never writes.
public struct PlayHistoryRepository: Sendable {
    /// Which sources to list.
    public enum SourceFilter: String, CaseIterable, Hashable, Sendable {
        case all
        case local
        case imported
    }

    // MARK: - Properties

    private let database: Database
    private let log = AppLogger.make(.persistence)

    // MARK: - Init

    /// Creates a repository backed by `database`.
    public init(database: Database) {
        self.database = database
    }

    // MARK: - Read

    /// The newest `limit` listens (all of them when nil), optionally only
    /// listens of songs matching `term` through the same FTS5 index and
    /// escaping the library search uses, so a song findable in Songs is
    /// findable here with the same text. Both sources filter the same way,
    /// because every listed row is a library song.
    ///
    /// Ties on `played_at` (two listens in one second) break on the row id,
    /// descending, so the order is total and stable across reloads.
    public func recent(
        limit: Int? = nil,
        matching term: String? = nil,
        source: SourceFilter = .all
    ) async throws -> [PlayHistoryRow] {
        let request = Self.request(limit: limit, matching: term, source: source)
        return try await self.database.read { db in
            try request.fetchAll(db)
        }
    }

    /// The same list as ``recent(limit:matching:source:)``, emitted
    /// immediately and again whenever a listed table changes, so a play
    /// that finishes while the page is open, or a re-match that links old
    /// listens to a song just added, appears without a reload.
    ///
    /// The tracked regions are the listen tables alone, not the joined song
    /// tables: the recorder's per-play `tracks` update lands in the same
    /// moment as its insert, and observing `tracks` as well would re-fetch
    /// the whole list on every rating, love or tag edit anywhere in the
    /// library. A title edited while the page is open shows on the next
    /// visit.
    public func observeRecent(
        limit: Int? = nil,
        matching term: String? = nil,
        source: SourceFilter = .all
    ) async -> AsyncThrowingStream<[PlayHistoryRow], Error> {
        let request = Self.request(limit: limit, matching: term, source: source)
        var regions: [any DatabaseRegionConvertible] = []
        if source != .imported {
            regions.append(Table("play_history"))
        }
        if source != .local {
            regions.append(Table("imported_listens"))
        }
        return await self.database.observe(regions: regions) { db in
            try request.fetchAll(db)
        }
    }

    // MARK: - Query

    /// The columns every branch of the union produces, in this order.
    private static let columns = """
           tracks.title AS title,
           artists.name AS artistName,
           albums.title AS albumName,
           tracks.artist_id AS artistID,
           tracks.album_id AS albumID,
           tracks.file_url AS fileURL,
           COALESCE(tracks.disabled, 1) AS isMissing
    """

    /// The local branch: a `LEFT JOIN` on every song table, so a play whose
    /// song row is missing lists with empty text rather than vanishing.
    private static let localBranch = """
    SELECT 'local' AS source,
           play_history.id AS rowID,
           play_history.played_at AS playedAt,
           play_history.track_id AS trackID,
    \(Self.columns)
    FROM play_history
    LEFT JOIN tracks ON tracks.id = play_history.track_id
    LEFT JOIN artists ON artists.id = tracks.artist_id
    LEFT JOIN albums ON albums.id = tracks.album_id
    """

    /// The imported branch: an inner join on `tracks`, which is what
    /// "matched to a library song" means, so unmatched rows never list.
    private static let importedBranch = """
    SELECT 'imported' AS source,
           imported_listens.id AS rowID,
           imported_listens.played_at AS playedAt,
           imported_listens.track_id AS trackID,
    \(Self.columns)
    FROM imported_listens
    JOIN tracks ON tracks.id = imported_listens.track_id
    LEFT JOIN artists ON artists.id = tracks.artist_id
    LEFT JOIN albums ON albums.id = tracks.album_id
    """

    static func request(limit: Int?, matching term: String?, source: SourceFilter) -> SQLRequest<PlayHistoryRow> {
        let trimmed = term?.trimmingCharacters(in: .whitespaces) ?? ""
        let escaped = trimmed.isEmpty ? nil : SQL.escapeFTSTerm(trimmed)
        var branches: [String] = []
        var arguments: [any DatabaseValueConvertible] = []

        func add(_ branch: String, matchColumn: String) {
            var sql = branch
            if let escaped {
                sql += "\nWHERE \(matchColumn) IN (SELECT rowid FROM tracks_fts WHERE tracks_fts MATCH ?)"
                arguments.append(escaped)
            }
            branches.append(sql)
        }
        if source != .imported {
            add(Self.localBranch, matchColumn: "play_history.track_id")
        }
        if source != .local {
            add(Self.importedBranch, matchColumn: "imported_listens.track_id")
        }

        var sql = branches.joined(separator: "\nUNION ALL\n")
        sql += "\nORDER BY playedAt DESC, rowID DESC"
        if let limit {
            sql += "\nLIMIT ?"
            arguments.append(limit)
        }
        return SQLRequest(sql: sql, arguments: StatementArguments(arguments))
    }
}
