import Foundation
import GRDB
import Observability

/// CRUD and query operations for the `tracks` table.
public struct TrackRepository: Sendable {
    // MARK: - Properties

    private let database: Database
    private let log = AppLogger.make(.persistence)

    // MARK: - Init

    /// Creates a repository backed by `database`.
    public init(database: Database) {
        self.database = database
    }

    // MARK: - Write

    /// Inserts `track` and returns the new `id`.
    @discardableResult
    public func insert(_ track: Track) async throws -> Int64 {
        let id: Int64 = try await self.database.write { db in
            var mutable = track
            try mutable.insert(db)
            guard let rowID = mutable.id else {
                throw PersistenceError.notFound(entity: "Track", id: -1)
            }
            return rowID
        }
        self.log.debug("track.insert", ["id": id])
        return id
    }

    /// Updates all columns of an existing `track`.
    public func update(_ track: Track) async throws {
        guard let id = track.id else { return }
        try await self.database.write { db in
            try track.update(db)
        }
        self.log.debug("track.update", ["id": id])
    }

    /// Inserts or replaces `track` keyed on `file_url`.
    ///
    /// Returns the `id` of the inserted or updated row (used by Phase 3 scanning).
    @discardableResult
    public func upsert(_ track: Track) async throws -> Int64 {
        let normalised = track.fileURL.precomposedStringWithCanonicalMapping
        let id: Int64 = try await self.database.write { db in
            var mutable = track
            // Normalise file_url before upsert to avoid phantom duplicates on APFS.
            mutable.fileURL = normalised
            try mutable.upsert(db)
            guard let rowID = mutable.id else {
                throw PersistenceError.notFound(entity: "Track", id: -1)
            }
            return rowID
        }
        self.log.debug("track.upsert", ["id": id])
        return id
    }

    /// Deletes the track with `id`.
    public func delete(id: Int64) async throws {
        let deleted: Bool = try await self.database.write { db in
            try Track.deleteOne(db, key: id)
        }
        self.log.debug("track.delete", ["id": id, "existed": deleted])
    }

    // MARK: - Read

    /// Fetches the track with `id`, or throws `.notFound` if absent.
    public func fetch(id: Int64) async throws -> Track {
        try await self.database.read { db in
            guard let track = try Track.fetchOne(db, key: id) else {
                throw PersistenceError.notFound(entity: "Track", id: id)
            }
            return track
        }
    }

    /// Fetches all tracks, newest first.
    public func fetchAll() async throws -> [Track] {
        try await self.database.read { db in
            try Track.order(Column("added_at").desc).fetchAll(db)
        }
    }

    /// Fetches all tracks for `albumID`.
    public func fetchAll(albumID: Int64) async throws -> [Track] {
        try await self.database.read { db in
            try Track
                .filter(Column("album_id") == albumID)
                .order(Column("disc_number"), Column("track_number"))
                .fetchAll(db)
        }
    }

    /// Fetches the track whose `file_url` matches `url` (after normalisation).
    public func fetchOne(fileURL: String) async throws -> Track? {
        let normalised = fileURL.precomposedStringWithCanonicalMapping
        return try await self.database.read { db in
            try Track.filter(Column("file_url") == normalised).fetchOne(db)
        }
    }

    /// Returns the total number of tracks in the library.
    public func count() async throws -> Int {
        try await self.database.read { db in
            try Track.fetchCount(db)
        }
    }
}
