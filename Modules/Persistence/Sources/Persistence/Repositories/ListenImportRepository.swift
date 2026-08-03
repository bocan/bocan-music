import Foundation
import GRDB
import Observability

/// Store for backfilled listening history (phase 25-1): idempotent bulk
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

    /// Case- and Unicode-normalised identity for artist+title matching.
    static func matchKey(artist: String, title: String) -> String {
        self.normalised(artist) + "\n" + self.normalised(title)
    }

    private static func normalised(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct LibraryKeys {
        let byMbid: [String: Int64]
        let byArtistTitle: [String: Int64]
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
        var byMbid: [String: Int64] = [:]
        var byArtistTitle: [String: Int64] = [:]
        for row in rows {
            guard let id: Int64 = row["id"] else { continue }
            if let mbid: String = row["mbid"], !mbid.isEmpty, byMbid[mbid] == nil {
                byMbid[mbid] = id
            }
            let title: String = row["title"] ?? ""
            guard !title.isEmpty else { continue }
            let key = self.matchKey(artist: row["artist_name"] ?? "", title: title)
            if byArtistTitle[key] == nil {
                byArtistTitle[key] = id
            }
        }
        return LibraryKeys(byMbid: byMbid, byArtistTitle: byArtistTitle)
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
            let mbid: String? = row["track_mbid"]
            let key = self.matchKey(artist: row["artist"] ?? "", title: row["title"] ?? "")
            guard let trackID = mbid.flatMap({ keys.byMbid[$0] }) ?? keys.byArtistTitle[key] else {
                continue
            }
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
