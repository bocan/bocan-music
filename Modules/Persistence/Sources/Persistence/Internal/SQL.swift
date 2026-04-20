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

    /// Returns albums whose album-artist name contains `term` (case-insensitive).
    ///
    /// Used to supplement FTS title search so artist-name queries surface relevant albums.
    static func albumsByArtistQuery(_ term: String) -> SQLRequest<Album> {
        SQLRequest(
            sql: """
            SELECT albums.*
            FROM albums
            LEFT JOIN artists ON artists.id = albums.album_artist_id
            WHERE artists.name LIKE ?
            ORDER BY albums.title
            """,
            arguments: ["%\(term)%"]
        )
    }

    // MARK: - Helpers

    /// Converts a user-supplied query into an FTS5 expression that supports
    /// prefix matching on every token.
    ///
    /// Each whitespace-delimited token is escaped (double-quotes doubled) and
    /// then wrapped as `"token"*` so FTS5 treats it as a prefix query.
    /// This means typing "boh" finds "Bohemian", "boh" etc.
    ///
    /// Special-character-only tokens are dropped to avoid FTS5 parse errors.
    static func escapeFTSTerm(_ term: String) -> String {
        let tokens = term
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .map { token -> String in
                let safe = token.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(safe)\"*"
            }
        // If nothing survived (e.g. pure whitespace input), fall back to a
        // quoted whole-phrase so the query is still syntactically valid.
        return tokens.isEmpty ? "\"\(term.replacingOccurrences(of: "\"", with: "\"\""))\"" : tokens.joined(separator: " ")
    }
}
