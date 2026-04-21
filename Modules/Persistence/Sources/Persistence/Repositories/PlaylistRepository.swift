import Foundation
import GRDB
import Observability

/// CRUD and ordering operations for the `playlists` and `playlist_tracks` tables.
///
/// This is a thin record-level wrapper around GRDB. Higher-level behaviour
/// (sparse-position reordering, folder-cycle checks, observation) lives in
/// `PlaylistService` in the `Library` module.
public struct PlaylistRepository: Sendable {
    // MARK: - Properties

    private let database: Database
    private let log = AppLogger.make(.persistence)

    // MARK: - Init

    /// Creates a repository backed by `database`.
    public init(database: Database) {
        self.database = database
    }

    // MARK: - Playlist write

    /// Inserts `playlist` and returns its new `id`.
    @discardableResult
    public func insert(_ playlist: Playlist) async throws -> Int64 {
        let id: Int64 = try await self.database.write { db in
            var mutable = playlist
            try mutable.insert(db)
            guard let rowID = mutable.id else {
                throw PersistenceError.notFound(entity: "Playlist", id: -1)
            }
            return rowID
        }
        self.log.debug("playlist.insert", ["id": id])
        return id
    }

    /// Updates all columns of an existing `playlist`.
    public func update(_ playlist: Playlist) async throws {
        guard let id = playlist.id else { return }
        try await self.database.write { db in
            try playlist.update(db)
        }
        self.log.debug("playlist.update", ["id": id])
    }

    /// Updates the `name` and `updated_at` of an existing playlist.
    public func updateName(id: Int64, name: String, now: Int64) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: "UPDATE playlists SET name = ?, updated_at = ? WHERE id = ?",
                arguments: [name, now, id]
            )
        }
        self.log.debug("playlist.rename", ["id": id])
    }

    /// Updates the `parent_id` and `updated_at` of an existing playlist.
    public func updateParent(id: Int64, parentID: Int64?, now: Int64) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: "UPDATE playlists SET parent_id = ?, updated_at = ? WHERE id = ?",
                arguments: [parentID, now, id]
            )
        }
        self.log.debug("playlist.reparent", ["id": id, "parent": parentID ?? -1])
    }

    /// Updates the `cover_art_path` and `updated_at` of an existing playlist.
    public func updateCoverArtPath(id: Int64, path: String?, now: Int64) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: "UPDATE playlists SET cover_art_path = ?, updated_at = ? WHERE id = ?",
                arguments: [path, now, id]
            )
        }
    }

    /// Updates the `accent_color` and `updated_at` of an existing playlist.
    public func updateAccentColor(id: Int64, hex: String?, now: Int64) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: "UPDATE playlists SET accent_color = ?, updated_at = ? WHERE id = ?",
                arguments: [hex, now, id]
            )
        }
    }

    /// Deletes the playlist with `id` (cascades to `playlist_tracks`).
    public func delete(id: Int64) async throws {
        let deleted: Bool = try await self.database.write { db in
            try Playlist.deleteOne(db, key: id)
        }
        self.log.debug("playlist.delete", ["id": id, "existed": deleted])
    }

    // MARK: - Playlist read

    /// Fetches the playlist with `id`, or throws `.notFound` if absent.
    public func fetch(id: Int64) async throws -> Playlist {
        try await self.database.read { db in
            guard let playlist = try Playlist.fetchOne(db, key: id) else {
                throw PersistenceError.notFound(entity: "Playlist", id: id)
            }
            return playlist
        }
    }

    /// Fetches all playlists in user-defined display order.
    public func fetchAll() async throws -> [Playlist] {
        try await self.database.read { db in
            try Playlist.order(Column("sort_order"), Column("name")).fetchAll(db)
        }
    }

    /// Fetches the direct children of `parentID` (root when `nil`), sorted by
    /// `sort_order` then `name`.
    public func fetchChildren(parentID: Int64?) async throws -> [Playlist] {
        try await self.database.read { db in
            if let parentID {
                return try Playlist
                    .filter(Column("parent_id") == parentID)
                    .order(Column("sort_order"), Column("name"))
                    .fetchAll(db)
            }
            return try Playlist
                .filter(Column("parent_id") == nil)
                .order(Column("sort_order"), Column("name"))
                .fetchAll(db)
        }
    }

    // MARK: - Track membership write

    /// Appends `trackID` to `playlistID` at the next available position.
    ///
    /// Uses a 1-step position; prefer `insertTracks(_:at:in:)` for the
    /// sparse positioning scheme expected by `PlaylistService`.
    public func appendTrack(trackID: Int64, to playlistID: Int64) async throws {
        try await self.database.write { db in
            let maxPos = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(position), 0) FROM playlist_tracks WHERE playlist_id = ?",
                arguments: [playlistID]
            ) ?? 0
            let entry = PlaylistTrack(
                playlistID: playlistID,
                trackID: trackID,
                position: maxPos + 1
            )
            try entry.insert(db)
        }
        self.log.debug("playlist_track.append", ["playlist": playlistID, "track": trackID])
    }

    /// Inserts `rows` (already-positioned) into `playlistID`.
    ///
    /// Positions in `rows` must not collide with existing positions in
    /// the playlist; the caller (`PlaylistService`) is responsible for
    /// picking them.
    public func insertRows(_ rows: [PlaylistTrack], in playlistID: Int64) async throws {
        guard !rows.isEmpty else { return }
        try await self.database.write { db in
            for row in rows {
                precondition(row.playlistID == playlistID, "row does not belong to playlist")
                try row.insert(db)
            }
        }
    }

    /// Removes `trackID` from `playlistID` (all occurrences).
    public func removeTrack(trackID: Int64, from playlistID: Int64) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: "DELETE FROM playlist_tracks WHERE playlist_id = ? AND track_id = ?",
                arguments: [playlistID, trackID]
            )
        }
        self.log.debug("playlist_track.remove", ["playlist": playlistID, "track": trackID])
    }

    /// Removes rows at the given positions from `playlistID`.
    public func removePositions(_ positions: [Int], from playlistID: Int64) async throws {
        guard !positions.isEmpty else { return }
        try await self.database.write { db in
            // Bind positions one at a time; IN (?) with an array isn't supported
            // by the SQLite binding layer without explicit marker expansion.
            let markers = positions.map { _ in "?" }.joined(separator: ",")
            let args: [DatabaseValueConvertible] = [playlistID] + positions.map { $0 as DatabaseValueConvertible }
            try db.execute(
                sql: "DELETE FROM playlist_tracks WHERE playlist_id = ? AND position IN (\(markers))",
                arguments: StatementArguments(args)
            )
        }
    }

    /// Deletes every track membership row for `playlistID`.
    public func clearMembership(playlistID: Int64) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: "DELETE FROM playlist_tracks WHERE playlist_id = ?",
                arguments: [playlistID]
            )
        }
    }

    /// Rewrites every position for a playlist in a single transaction.
    ///
    /// `ordered` is the full list of `(trackID, newPosition)` tuples in the
    /// order they should be stored. Callers (the repack helper) must provide
    /// a complete replacement so the `(playlist_id, position)` unique key
    /// is never momentarily violated.
    public func replaceMembership(playlistID: Int64, ordered: [(trackID: Int64, position: Int)]) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: "DELETE FROM playlist_tracks WHERE playlist_id = ?",
                arguments: [playlistID]
            )
            for row in ordered {
                try db.execute(
                    sql: "INSERT INTO playlist_tracks (playlist_id, track_id, position) VALUES (?, ?, ?)",
                    arguments: [playlistID, row.trackID, row.position]
                )
            }
        }
    }

    // MARK: - Track membership read

    /// Returns the ordered track IDs for `playlistID`.
    public func fetchTrackIDs(playlistID: Int64) async throws -> [Int64] {
        try await self.database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT track_id FROM playlist_tracks WHERE playlist_id = ? ORDER BY position",
                arguments: [playlistID]
            )
            return rows.map { $0["track_id"] }
        }
    }

    /// Returns `(trackID, position)` pairs for `playlistID` in order.
    public func fetchMembership(playlistID: Int64) async throws -> [(trackID: Int64, position: Int)] {
        try await self.database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT track_id, position FROM playlist_tracks WHERE playlist_id = ? ORDER BY position",
                arguments: [playlistID]
            )
            return rows.map { (trackID: $0["track_id"], position: $0["position"]) }
        }
    }

    /// Returns the ordered `Track` rows for `playlistID`.
    public func fetchTracks(playlistID: Int64) async throws -> [Track] {
        try await self.database.read { db in
            try Track.fetchAll(
                db,
                sql: """
                SELECT tracks.* FROM tracks
                INNER JOIN playlist_tracks ON playlist_tracks.track_id = tracks.id
                WHERE playlist_tracks.playlist_id = ?
                ORDER BY playlist_tracks.position
                """,
                arguments: [playlistID]
            )
        }
    }

    /// Returns the count of tracks in `playlistID`.
    public func trackCount(playlistID: Int64) async throws -> Int {
        try await self.database.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM playlist_tracks WHERE playlist_id = ?",
                arguments: [playlistID]
            ) ?? 0
        }
    }

    /// Returns the sum of `tracks.duration` across membership of `playlistID`.
    public func totalDuration(playlistID: Int64) async throws -> TimeInterval {
        try await self.database.read { db in
            try Double.fetchOne(
                db,
                sql: """
                SELECT COALESCE(SUM(tracks.duration), 0) FROM tracks
                INNER JOIN playlist_tracks ON playlist_tracks.track_id = tracks.id
                WHERE playlist_tracks.playlist_id = ?
                """,
                arguments: [playlistID]
            ) ?? 0
        }
    }
}
