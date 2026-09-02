import Foundation
import GRDB

/// Typed access to the transcode ledger (`sync_transcodes`, ADR-088).
///
/// Written by the SyncServer transcode coordinator (rows) and file serving
/// (`served_at`); read by the manifest builder, file serving, and the
/// coordinator's release sweep. The ledger, not the filesystem, is what the
/// manifest hot path consults: hashing happens once, at encode time.
public struct SyncTranscodeRepository: Sendable {
    private let database: Database

    public init(database: Database) {
        self.database = database
    }

    /// Inserts or replaces the row for the transcode's (track, preset) pair.
    public func upsert(_ transcode: SyncTranscode) async throws {
        try await self.database.write { db in
            try transcode.save(db, onConflict: .replace)
        }
    }

    /// The row for (track, preset), but only while it was derived from the
    /// given source hash; `nil` when absent or stale. This is the validity
    /// rule of ADR-088: a retagged file's old artifact never gets served.
    public func validRow(
        trackID: Int64,
        preset: String,
        sourceContentHash: String
    ) async throws -> SyncTranscode? {
        try await self.database.read { db in
            try SyncTranscode.fetchOne(
                db,
                sql: """
                SELECT * FROM sync_transcodes
                WHERE track_id = ? AND preset = ? AND source_content_hash = ?
                """,
                arguments: [trackID, preset, sourceContentHash]
            )
        }
    }

    /// Every row for `preset` whose source hash still matches its track's
    /// current `content_hash`. The manifest builder's bulk read.
    public func allValid(preset: String) async throws -> [SyncTranscode] {
        try await self.database.read { db in
            try SyncTranscode.fetchAll(
                db,
                sql: """
                SELECT sync_transcodes.* FROM sync_transcodes
                JOIN tracks ON tracks.id = sync_transcodes.track_id
                WHERE sync_transcodes.preset = ?
                  AND tracks.content_hash = sync_transcodes.source_content_hash
                ORDER BY sync_transcodes.track_id
                """,
                arguments: [preset]
            )
        }
    }

    /// Stamps the moment a file response delivered the artifact through EOF.
    /// The release sweep deletes the bytes of stamped rows (unless the keep
    /// toggle is on); the row itself stays.
    public func stampServed(trackID: Int64, preset: String, at unixSeconds: Int64) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: "UPDATE sync_transcodes SET served_at = ? WHERE track_id = ? AND preset = ?",
                arguments: [unixSeconds, trackID, preset]
            )
        }
    }

    /// Removes one (track, preset) row: the track left the sync selection or
    /// stopped qualifying for transcoding. The caller reaps the bytes.
    public func delete(trackID: Int64, preset: String) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: "DELETE FROM sync_transcodes WHERE track_id = ? AND preset = ?",
                arguments: [trackID, preset]
            )
        }
    }

    /// Removes every row for `preset`. Used when the sync profile switches
    /// rungs; the caller deletes the preset's workspace directory alongside.
    @discardableResult
    public func deleteAll(preset: String) async throws -> Int {
        try await self.database.write { db in
            try db.execute(sql: "DELETE FROM sync_transcodes WHERE preset = ?", arguments: [preset])
            return db.changesCount
        }
    }

    /// Removes rows whose source hash no longer matches the track's current
    /// `content_hash` (retagged or replaced files) or whose track vanished
    /// without the cascade firing. Returns how many went; the caller deletes
    /// any lingering artifact bytes for them.
    @discardableResult
    public func deleteStale(preset: String) async throws -> [SyncTranscode] {
        try await self.database.write { db in
            let stale = try SyncTranscode.fetchAll(
                db,
                sql: """
                SELECT sync_transcodes.* FROM sync_transcodes
                LEFT JOIN tracks ON tracks.id = sync_transcodes.track_id
                WHERE sync_transcodes.preset = ?
                  AND (tracks.id IS NULL OR tracks.content_hash IS NOT sync_transcodes.source_content_hash)
                """,
                arguments: [preset]
            )
            for row in stale {
                try db.execute(
                    sql: "DELETE FROM sync_transcodes WHERE track_id = ? AND preset = ?",
                    arguments: [row.trackID, row.preset]
                )
            }
            return stale
        }
    }
}
