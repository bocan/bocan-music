import GRDB
import Observability

/// Read/write per-track and per-album EQ preset assignments.
///
/// Rows in `track_dsp_assignments` and `album_dsp_assignments` are optional; absence
/// means "use the global EQ preset".  The `eq_preset_id` column stores an `EQPreset.id`
/// string (either `"bocan.*"` for built-ins or a UUID string for user presets).
///
/// Priority order at playback time: track assignment → album assignment → global.
public struct DSPAssignmentRepository: Sendable {
    // MARK: - Properties

    private let database: Database
    private let log = AppLogger.make(.persistence)

    // MARK: - Init

    public init(database: Database) {
        self.database = database
    }

    // MARK: - Resolution

    /// Returns the highest-priority EQ preset ID for the given track/album pair.
    ///
    /// Returns `nil` when neither has a scoped assignment (caller should use global).
    public func resolvePresetID(trackID: Int64, albumID: Int64?) async throws -> String? {
        if let id = try await fetchTrackPresetID(trackID: trackID) { return id }
        if let albumID, let id = try await fetchAlbumPresetID(albumID: albumID) { return id }
        return nil
    }

    // MARK: - Track assignments

    /// Returns the EQ preset ID assigned to `trackID`, or `nil` if none is set.
    public func fetchTrackPresetID(trackID: Int64) async throws -> String? {
        try await self.database.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT eq_preset_id FROM track_dsp_assignments WHERE track_id = ?",
                arguments: [trackID]
            )
            return row?["eq_preset_id"] as? String
        }
    }

    /// Assigns `presetID` to `trackID`, replacing any existing assignment.
    public func setTrackPreset(trackID: Int64, presetID: String) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: """
                INSERT INTO track_dsp_assignments (track_id, eq_preset_id)
                VALUES (?, ?)
                ON CONFLICT(track_id) DO UPDATE SET eq_preset_id = excluded.eq_preset_id
                """,
                arguments: [trackID, presetID]
            )
        }
        self.log.debug("dsp.track.set", ["trackID": trackID, "presetID": presetID])
    }

    /// Removes any EQ preset assignment for `trackID`.
    public func clearTrackPreset(trackID: Int64) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: "DELETE FROM track_dsp_assignments WHERE track_id = ?",
                arguments: [trackID]
            )
        }
        self.log.debug("dsp.track.clear", ["trackID": trackID])
    }

    // MARK: - Album assignments

    /// Returns the EQ preset ID assigned to `albumID`, or `nil` if none is set.
    public func fetchAlbumPresetID(albumID: Int64) async throws -> String? {
        try await self.database.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT eq_preset_id FROM album_dsp_assignments WHERE album_id = ?",
                arguments: [albumID]
            )
            return row?["eq_preset_id"] as? String
        }
    }

    /// Assigns `presetID` to `albumID`, replacing any existing assignment.
    public func setAlbumPreset(albumID: Int64, presetID: String) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: """
                INSERT INTO album_dsp_assignments (album_id, eq_preset_id)
                VALUES (?, ?)
                ON CONFLICT(album_id) DO UPDATE SET eq_preset_id = excluded.eq_preset_id
                """,
                arguments: [albumID, presetID]
            )
        }
        self.log.debug("dsp.album.set", ["albumID": albumID, "presetID": presetID])
    }

    /// Removes any EQ preset assignment for `albumID`.
    public func clearAlbumPreset(albumID: Int64) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: "DELETE FROM album_dsp_assignments WHERE album_id = ?",
                arguments: [albumID]
            )
        }
        self.log.debug("dsp.album.clear", ["albumID": albumID])
    }
}
