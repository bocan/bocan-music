import Foundation
import GRDB
import Observability

// MARK: - MaintenanceRepository

/// User-initiated database repair operations (Settings > Advanced).
public struct MaintenanceRepository: Sendable {
    /// Row counts written by a rebuild, for the settings pane's result line.
    public struct FTSRebuildCounts: Sendable, Equatable {
        public let tracks: Int
        public let artists: Int
        public let albums: Int

        public var total: Int {
            self.tracks + self.artists + self.albums
        }
    }

    private let database: Database
    private let log = AppLogger.make(.persistence)

    public init(database: Database) {
        self.database = database
    }

    /// Drops and repopulates all three FTS5 indexes from their source tables
    /// in one transaction, mirroring the M001 trigger SELECTs exactly.
    ///
    /// The triggers keep the indexes correct during normal operation (M014
    /// closed the artist/album-rename gap), so this is a repair tool for the
    /// abnormal: a crash-corrupted FTS shadow table, hand edits made via
    /// "Reveal Database in Finder", or residue from a historic trigger bug.
    public func rebuildFTSIndexes() async throws -> FTSRebuildCounts {
        self.log.debug("maintenance.ftsRebuild.start")
        let start = Date()
        let counts = try await self.database.write { db -> FTSRebuildCounts in
            try db.execute(sql: "DELETE FROM tracks_fts")
            try db.execute(
                sql: """
                INSERT INTO tracks_fts(rowid, title, composer, genre, artist_name, album_title)
                SELECT
                    t.id,
                    COALESCE(t.title, ''),
                    COALESCE(t.composer, ''),
                    COALESCE(t.genre, ''),
                    COALESCE(a.name, ''),
                    COALESCE(al.title, '')
                FROM tracks t
                LEFT JOIN artists a ON a.id = t.artist_id
                LEFT JOIN albums al ON al.id = t.album_id
                """
            )
            try db.execute(sql: "DELETE FROM artists_fts")
            try db.execute(
                sql: """
                INSERT INTO artists_fts(rowid, name, sort_name)
                SELECT id, COALESCE(name, ''), COALESCE(sort_name, '') FROM artists
                """
            )
            try db.execute(sql: "DELETE FROM albums_fts")
            try db.execute(
                sql: """
                INSERT INTO albums_fts(rowid, title)
                SELECT id, COALESCE(title, '') FROM albums
                """
            )
            return try FTSRebuildCounts(
                tracks: Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks_fts") ?? 0,
                artists: Int.fetchOne(db, sql: "SELECT COUNT(*) FROM artists_fts") ?? 0,
                albums: Int.fetchOne(db, sql: "SELECT COUNT(*) FROM albums_fts") ?? 0
            )
        }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        self.log.debug("maintenance.ftsRebuild.end", [
            "tracks": counts.tracks, "artists": counts.artists, "albums": counts.albums, "ms": ms,
        ])
        return counts
    }
}
