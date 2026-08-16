import Foundation
import GRDB
import Observability

/// Store for backfilled listening history (ADR-076 slice 1): idempotent bulk
/// insert, the library re-match pass, and honest coverage counts.
///
/// Imports never touch `play_history` or the per-track counters, so local
/// stats stay canonical and the whole import stays reversible with
/// ``removeAll()``.
public struct ListenImportRepository: Sendable {
    // MARK: - Properties

    private let database: Database
    private let log = AppLogger.make(.persistence)

    /// Window within which a matched imported play and a local play of the
    /// same track count as the same listen: Bòcan scrobbled that play to
    /// Last.fm, so the export echoes `play_history`.
    public static let overlapWindowSeconds: Int64 = 300

    // MARK: - Init

    /// Creates a repository backed by `database`.
    public init(database: Database) {
        self.database = database
    }

    // MARK: - Insert

    /// Inserts a batch, ignoring rows already imported (the unique identity
    /// index makes re-imports idempotent). Returns how many rows were new.
    public func insert(_ listens: [ImportedListen]) async throws -> Int {
        guard !listens.isEmpty else { return 0 }
        let inserted: Int = try await self.database.write { db in
            var count = 0
            for listen in listens {
                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO imported_listens
                        (source, played_at, artist, title, album, track_mbid)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        listen.source,
                        listen.playedAt,
                        listen.artist,
                        listen.title,
                        listen.album,
                        listen.trackMbid,
                    ]
                )
                count += db.changesCount
            }
            return count
        }
        self.log.debug("listens.insert", ["batch": listens.count, "inserted": inserted])
        return inserted
    }

    // MARK: - Matching

    /// Outcome of one re-match pass.
    public struct RematchSummary: Equatable, Sendable {
        /// Rows that gained a `track_id` this pass.
        public let newlyMatched: Int
        /// Matched rows dropped because a local play already records the
        /// same listen (see ``overlapWindowSeconds``).
        public let overlapRemoved: Int
    }

    /// Links unmatched rows to library tracks (MusicBrainz id first, then
    /// normalised artist+title) and drops rows that duplicate local plays.
    /// Cheap and idempotent; run it again whenever the library grows.
    public func rematch() async throws -> RematchSummary {
        let summary: RematchSummary = try await self.database.write { db in
            let matched = try Self.applyMatches(db)
            let removed = try Self.removeLocalOverlaps(db)
            return RematchSummary(newlyMatched: matched, overlapRemoved: removed)
        }
        self.log.info("listens.rematch", [
            "matched": summary.newlyMatched,
            "overlapRemoved": summary.overlapRemoved,
        ])
        return summary
    }

    // MARK: - Coverage

    /// Import coverage for the Listening Behaviour tab.
    public struct Counts: Equatable, Sendable {
        /// Imported rows currently stored.
        public let total: Int
        /// Rows linked to a library track.
        public let matched: Int

        /// Rows still awaiting a match.
        public var unmatched: Int {
            self.total - self.matched
        }

        public init(total: Int, matched: Int) {
            self.total = total
            self.matched = matched
        }
    }

    /// Current totals in one read.
    public func counts() async throws -> Counts {
        try await self.database.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS total,
                       COALESCE(SUM(track_id IS NOT NULL), 0) AS matched
                FROM imported_listens
            """)
            return Counts(total: row?["total"] ?? 0, matched: row?["matched"] ?? 0)
        }
    }

    // MARK: - Removal

    /// Deletes every imported row: the one-statement undo the import promises.
    @discardableResult
    public func removeAll() async throws -> Int {
        let removed: Int = try await self.database.write { db in
            try db.execute(sql: "DELETE FROM imported_listens")
            return db.changesCount
        }
        self.log.info("listens.removeAll", ["removed": removed])
        return removed
    }

    // MARK: - Internal matching machinery

    /// Case- and Unicode-normalised identity for artist+title matching
    /// (tier one: exact after lowercasing).
    static func matchKey(artist: String, title: String) -> String {
        self.normalised(artist) + "\n" + self.normalised(title)
    }

    /// Tier two: typography folded on top of tier one. Curly apostrophes and
    /// quotes, en/em dashes, collapsed whitespace, and "&" versus "and" are
    /// the difference between a library rip and a streaming-era scrobble far
    /// more often than the actual words are (measured on a real export).
    static func foldedKey(artist: String, title: String) -> String {
        self.folded(artist) + "\n" + self.folded(title)
    }

    /// Tier three: tier two plus edition qualifiers stripped from the title
    /// ("- 2015 Remaster", "(Album Version)", "- Radio Edit", "(Live)").
    /// Applied to both sides, so it heals a suffix on either. For listening
    /// history this is the right trade: a play of the remaster credited to
    /// the rip beats a play credited to nothing.
    static func strippedKey(artist: String, title: String) -> String {
        self.folded(artist) + "\n" + self.strippedTitle(title)
    }

    private static func normalised(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func folded(_ value: String) -> String {
        var folded = self.normalised(value)
        for (fancy, plain) in [("\u{2019}", "'"), ("\u{2018}", "'"), ("\u{201C}", "\""), ("\u{201D}", "\"")] {
            folded = folded.replacingOccurrences(of: fancy, with: plain)
        }
        folded = folded.replacingOccurrences(of: "\u{2013}", with: "-")
        folded = folded.replacingOccurrences(of: "\u{2014}", with: "-")
        folded = folded.replacingOccurrences(of: " & ", with: " and ")
        return folded.split(separator: " ").joined(separator: " ")
    }

    /// Trailing edition qualifiers, stripped repeatedly so stacked suffixes
    /// ("Song - Radio Edit - 2011 Remaster") unwind fully.
    /// nonisolated(unsafe): `Regex` lacks Sendable, but this literal is
    /// immutable after initialisation and matching does not mutate it.
    private nonisolated(unsafe) static let titleQualifier = #/
        \s* (?: - | \( ) \s*
        (?: (?: \d{4} \s )? remaster (?: ed )? (?: \s \d{4} )? (?: \s version )?
          | single \s version | album \s version | radio \s edit
          | live (?: \s [^)]* )? | acoustic (?: \s version )?
          | feat \. [^)]* | bonus \s track | deluxe (?: \s [^)]* )? | explicit | mono | stereo
        ) \)? \s* $
    /#.ignoresCase()

    private static func strippedTitle(_ value: String) -> String {
        var title = self.folded(value)
        while true {
            let stripped = title.replacing(Self.titleQualifier, with: "").trimmingCharacters(in: .whitespaces)
            if stripped == title || stripped.isEmpty {
                return title
            }
            title = stripped
        }
    }

    private struct LibraryKeys {
        var byMbid: [String: Int64] = [:]
        var exact: [String: Int64] = [:]
        var folded: [String: Int64] = [:]
        var stripped: [String: Int64] = [:]

        /// Strictest tier first; a looser tier never overrides a stricter hit.
        func trackID(mbid: String?, artist: String, title: String) -> Int64? {
            if let mbid, let hit = self.byMbid[mbid] {
                return hit
            }
            return self.exact[ListenImportRepository.matchKey(artist: artist, title: title)]
                ?? self.folded[ListenImportRepository.foldedKey(artist: artist, title: title)]
                ?? self.stripped[ListenImportRepository.strippedKey(artist: artist, title: title)]
        }
    }

    private static func libraryKeys(_ db: GRDB.Database) throws -> LibraryKeys {
        let rows = try Row.fetchAll(db, sql: """
            SELECT tracks.id AS id,
                   tracks.title AS title,
                   tracks.musicbrainz_track_id AS mbid,
                   artists.name AS artist_name
            FROM tracks
            LEFT JOIN artists ON artists.id = tracks.artist_id
            WHERE tracks.disabled = 0
        """)
        var keys = LibraryKeys()
        for row in rows {
            guard let id: Int64 = row["id"] else { continue }
            if let mbid: String = row["mbid"], !mbid.isEmpty, keys.byMbid[mbid] == nil {
                keys.byMbid[mbid] = id
            }
            let title: String = row["title"] ?? ""
            guard !title.isEmpty else { continue }
            let artist: String = row["artist_name"] ?? ""
            for (key, tier) in [
                (self.matchKey(artist: artist, title: title), \LibraryKeys.exact),
                (self.foldedKey(artist: artist, title: title), \LibraryKeys.folded),
                (self.strippedKey(artist: artist, title: title), \LibraryKeys.stripped),
            ] where keys[keyPath: tier][key] == nil {
                keys[keyPath: tier][key] = id
            }
        }
        return keys
    }

    private static func applyMatches(_ db: GRDB.Database) throws -> Int {
        let keys = try self.libraryKeys(db)
        let unmatched = try Row.fetchAll(
            db,
            sql: "SELECT id, artist, title, track_mbid FROM imported_listens WHERE track_id IS NULL"
        )
        var matched = 0
        for row in unmatched {
            guard let id: Int64 = row["id"] else { continue }
            let trackID = keys.trackID(
                mbid: row["track_mbid"],
                artist: row["artist"] ?? "",
                title: row["title"] ?? ""
            )
            guard let trackID else { continue }
            try db.execute(
                sql: "UPDATE imported_listens SET track_id = ? WHERE id = ?",
                arguments: [trackID, id]
            )
            matched += 1
        }
        return matched
    }

    /// `overlapWindowSeconds` is a trusted numeric constant, never user input.
    private static func removeLocalOverlaps(_ db: GRDB.Database) throws -> Int {
        try db.execute(sql: """
            DELETE FROM imported_listens
            WHERE track_id IS NOT NULL AND EXISTS (
                SELECT 1 FROM play_history
                WHERE play_history.track_id = imported_listens.track_id
                  AND ABS(play_history.played_at - imported_listens.played_at) <= \(self.overlapWindowSeconds)
            )
        """)
        return db.changesCount
    }
}
