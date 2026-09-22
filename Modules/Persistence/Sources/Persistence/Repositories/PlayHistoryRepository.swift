import Foundation
import GRDB
import Observability

/// Reads `play_history` back as a list, newest first (ADR-094).
///
/// The only writer of the table is `PlayHistoryRecorder` in `Playback`; this
/// repository never writes. Each row is one play joined to its song's display
/// text, so the page renders without a second lookup per row.
public struct PlayHistoryRepository: Sendable {
    // MARK: - Properties

    private let database: Database
    private let log = AppLogger.make(.persistence)

    // MARK: - Init

    /// Creates a repository backed by `database`.
    public init(database: Database) {
        self.database = database
    }

    // MARK: - Read

    /// Every play, newest first, optionally only plays of songs matching
    /// `term` through the same FTS5 index and escaping the library search
    /// uses, so a song findable in Songs is findable here with the same text.
    ///
    /// Ties on `played_at` (two plays in one second) break on the play id,
    /// descending, so the order is total and stable across reloads.
    public func recent(limit: Int? = nil, matching term: String? = nil) async throws -> [PlayHistoryRow] {
        let request = Self.request(limit: limit, matching: term)
        return try await self.database.read { db in
            try request.fetchAll(db)
        }
    }

    /// The same list as ``recent(limit:matching:)``, emitted immediately and
    /// again whenever `play_history` changes, so a play that finishes while
    /// the page is open appears without a reload.
    ///
    /// The tracked region is the `play_history` table alone, not the joined
    /// song tables: the recorder's per-play `tracks` update lands in the same
    /// moment as the insert, and observing `tracks` as well would re-fetch the
    /// whole list on every rating, love or tag edit anywhere in the library.
    /// A title edited while the page is open shows on the next visit.
    public func observeRecent(
        limit: Int? = nil,
        matching term: String? = nil
    ) async -> AsyncThrowingStream<[PlayHistoryRow], Error> {
        let request = Self.request(limit: limit, matching: term)
        return await self.database.observe(regions: [Table("play_history")]) { db in
            try request.fetchAll(db)
        }
    }

    // MARK: - Query

    /// The joined read. `LEFT JOIN` on every song table, so a play whose
    /// song row is missing lists with empty text rather than vanishing.
    static func request(limit: Int?, matching term: String?) -> SQLRequest<PlayHistoryRow> {
        var sql = """
        SELECT play_history.id AS playID,
               play_history.track_id AS trackID,
               play_history.played_at AS playedAt,
               tracks.title AS title,
               artists.name AS artistName,
               albums.title AS albumName,
               tracks.artist_id AS artistID,
               tracks.album_id AS albumID,
               tracks.file_url AS fileURL,
               COALESCE(tracks.disabled, 1) AS isMissing
        FROM play_history
        LEFT JOIN tracks ON tracks.id = play_history.track_id
        LEFT JOIN artists ON artists.id = tracks.artist_id
        LEFT JOIN albums ON albums.id = tracks.album_id
        """
        var arguments: [any DatabaseValueConvertible] = []
        let trimmed = term?.trimmingCharacters(in: .whitespaces) ?? ""
        if !trimmed.isEmpty {
            sql += """

            WHERE play_history.track_id IN (
                SELECT rowid FROM tracks_fts WHERE tracks_fts MATCH ?
            )
            """
            arguments.append(SQL.escapeFTSTerm(trimmed))
        }
        sql += "\nORDER BY play_history.played_at DESC, play_history.id DESC"
        if let limit {
            sql += "\nLIMIT ?"
            arguments.append(limit)
        }
        return SQLRequest(sql: sql, arguments: StatementArguments(arguments))
    }
}
