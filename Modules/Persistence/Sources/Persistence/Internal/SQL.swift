import GRDB

/// Helpers for common raw-SQL patterns used across the module.
///
/// This is an internal utility type; do not expose it in the public API.
enum SQL {
    // MARK: - FTS

    /// Returns an FTS5 MATCH expression that queries `tracks_fts`.
    static func tracksFTSQuery(_ term: String) -> SQLRequest<Track> {
        let escaped = Self.escapeFTSTerm(term)
        return SQLRequest(
            sql: """
            SELECT tracks.*
            FROM tracks
            JOIN tracks_fts ON tracks_fts.rowid = tracks.id
            WHERE tracks_fts MATCH ?
            ORDER BY rank
            """,
            arguments: [escaped]
        )
    }

    /// Like `tracksFTSQuery` but JOINs `artists` and `albums` to return a
    /// `TrackSearchHit` with denormalised artist name and album cover-art path.
    static func tracksFTSRichQuery(_ term: String) -> SQLRequest<TrackSearchHit> {
        let escaped = Self.escapeFTSTerm(term)
        return SQLRequest(
            sql: """
            SELECT tracks.*,
                   artists.name       AS srch_artist_name,
                   albums.cover_art_path AS srch_cover_art_path
            FROM tracks
            JOIN tracks_fts ON tracks_fts.rowid = tracks.id
            LEFT JOIN artists ON artists.id = tracks.artist_id
            LEFT JOIN albums  ON albums.id  = tracks.album_id
            WHERE tracks_fts MATCH ?
            ORDER BY rank
            """,
            arguments: [escaped]
        )
    }

    /// Returns an FTS5 MATCH expression that queries `artists_fts`.
    static func artistsFTSQuery(_ term: String) -> SQLRequest<Artist> {
        let escaped = Self.escapeFTSTerm(term)
        return SQLRequest(
            sql: """
            SELECT artists.*
            FROM artists
            JOIN artists_fts ON artists_fts.rowid = artists.id
            WHERE artists_fts MATCH ?
            ORDER BY rank
            """,
            arguments: [escaped]
        )
    }

    /// Returns an FTS5 MATCH expression that queries `albums_fts`.
    static func albumsFTSQuery(_ term: String) -> SQLRequest<Album> {
        let escaped = Self.escapeFTSTerm(term)
        return SQLRequest(
            sql: """
            SELECT albums.*
            FROM albums
            JOIN albums_fts ON albums_fts.rowid = albums.id
            WHERE albums_fts MATCH ?
            ORDER BY rank
            """,
            arguments: [escaped]
        )
    }

    // MARK: - Helpers

    /// Escapes a user-supplied FTS search term to prevent injection.
    ///
    /// FTS5 special characters (`"`, `*`, `^`, etc.) are handled by quoting
    /// the entire phrase.  Double-quotes inside the term are doubled.
    static func escapeFTSTerm(_ term: String) -> String {
        let sanitised = term.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(sanitised)\""
    }
}
