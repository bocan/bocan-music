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
              AND tracks.disabled = 0
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
              AND tracks.disabled = 0
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
        let escaped = Self.escapeLIKETerm(term)
        return SQLRequest(
            sql: """
            SELECT albums.*
            FROM albums
            LEFT JOIN artists ON artists.id = albums.album_artist_id
            WHERE artists.name LIKE ? ESCAPE '\\'
            ORDER BY albums.title
            """,
            arguments: ["%\(escaped)%"]
        )
    }

    /// Returns albums that contain at least one non-disabled track whose
    /// indexed metadata matches `term` via `tracks_fts`. Lets album search
    /// surface results where the album/artist names don't contain the term
    /// but one of the album's songs does — matching Subsonic's `search3`
    /// album behaviour.
    static func albumsByTrackFTSQuery(_ term: String) -> SQLRequest<Album> {
        let escaped = Self.escapeFTSTerm(term)
        return SQLRequest(
            sql: """
            SELECT DISTINCT albums.*
            FROM albums
            JOIN tracks ON tracks.album_id = albums.id
            JOIN tracks_fts ON tracks_fts.rowid = tracks.id
            WHERE tracks_fts MATCH ?
              AND tracks.disabled = 0
            ORDER BY albums.title
            """,
            arguments: [escaped]
        )
    }

    /// Returns albums whose release year equals `year`.
    ///
    /// Supplements FTS title search so a four-digit query like "1984"
    /// surfaces albums released that year (#378).
    static func albumsByYearQuery(_ year: Int) -> SQLRequest<Album> {
        SQLRequest(
            sql: """
            SELECT albums.*
            FROM albums
            WHERE albums.year = ?
            ORDER BY albums.title
            """,
            arguments: [year]
        )
    }

    /// Returns albums containing at least one non-disabled track whose raw
    /// date/year tag (`year_text`) starts with `prefix`.
    ///
    /// Many files carry proper dates ("2004-06-15", "1974-05") rather than a
    /// bare year; those survive only on `tracks.year_text`, since
    /// `albums.year` is an integer. This pass lets a date-shaped query narrow
    /// the album grid to a month or day, and covers albums whose integer year
    /// never got set.
    static func albumsByTrackYearTextQuery(_ prefix: String) -> SQLRequest<Album> {
        let escaped = Self.escapeLIKETerm(prefix)
        return SQLRequest(
            sql: """
            SELECT DISTINCT albums.*
            FROM albums
            JOIN tracks ON tracks.album_id = albums.id
            WHERE tracks.year_text LIKE ? ESCAPE '\\'
              AND tracks.disabled = 0
            ORDER BY albums.title
            """,
            arguments: ["\(escaped)%"]
        )
    }

    /// Interprets a search query as a release-year or release-date term.
    ///
    /// Returns non-`nil` only when the whole query is a year (exactly four
    /// ASCII digits, "1984") or a date beginning with one (four digits, a
    /// separator, then only digits and separators: "2004-06", "2004-06-15").
    /// Shorter digit runs never qualify, so "19" cannot swallow half a
    /// library. For a plain year, `year` carries the integer for matching
    /// `albums.year`; a fuller date matches only via `year_text` prefixes,
    /// so `year` stays `nil` and "2004-06" does not return every 2004 album.
    static func yearSearchTerm(_ term: String) -> (year: Int?, dateTextPrefix: String)? {
        func isASCIIDigit(_ char: Character) -> Bool {
            char.isASCII && char.isNumber
        }
        let separators: Set<Character> = ["-", ".", "/"]
        guard term.count >= 4, term.prefix(4).allSatisfy(isASCIIDigit) else { return nil }
        let rest = term.dropFirst(4)
        if rest.isEmpty {
            return (year: Int(term), dateTextPrefix: term)
        }
        guard let first = rest.first, separators.contains(first),
              rest.allSatisfy({ isASCIIDigit($0) || separators.contains($0) }) else {
            return nil
        }
        return (year: nil, dateTextPrefix: term)
    }

    // MARK: - LIKE helpers

    /// Escapes `%`, `_`, and `\` in a LIKE pattern operand so they are treated
    /// as literals rather than wildcards. The caller is responsible for appending
    /// the surrounding `%` wildcards and passing `ESCAPE '\'` in the SQL.
    static func escapeLIKETerm(_ term: String) -> String {
        term
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
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
