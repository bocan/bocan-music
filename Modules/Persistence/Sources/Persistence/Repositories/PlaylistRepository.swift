import Foundation
import GRDB
import Observability

/// CRUD and ordering operations for the `playlists` and `playlist_tracks` tables.
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

    // MARK: - Track membership write

    /// Appends `trackID` to `playlistID` at the next available position.
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
}
