import GRDB
import Observability

/// CRUD operations for the `albums` table.
public struct AlbumRepository: Sendable {
    // MARK: - Properties

    private let database: Database
    private let log = AppLogger.make(.persistence)

    // MARK: - Init

    /// Creates a repository backed by `database`.
    public init(database: Database) {
        self.database = database
    }

    // MARK: - Write

    /// Inserts `album` and returns its new `id`.
    @discardableResult
    public func insert(_ album: Album) async throws -> Int64 {
        let id: Int64 = try await self.database.write { db in
            var mutable = album
            try mutable.insert(db)
            guard let rowID = mutable.id else {
                throw PersistenceError.notFound(entity: "Album", id: -1)
            }
            return rowID
        }
        self.log.debug("album.insert", ["id": id])
        return id
    }

    /// Updates all columns of an existing `album`.
    public func update(_ album: Album) async throws {
        guard let id = album.id else { return }
        try await self.database.write { db in
            try album.update(db)
        }
        self.log.debug("album.update", ["id": id])
    }

    /// Links an album row to a cover-art `hash` and its on-disk `path`.
    ///
    /// Uses a direct `UPDATE` (rather than the record-level `update`) so a
    /// single failing column doesn't block the write, and so it's obvious at
    /// the SQL layer what's being changed.
    public func setCoverArt(albumID: Int64, hash: String, path: String) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: "UPDATE albums SET cover_art_hash = ?, cover_art_path = ? WHERE id = ?",
                arguments: [hash, path, albumID]
            )
        }
        self.log.debug("album.cover_art", ["id": albumID, "hash": hash])
    }

    /// Toggles the `force_gapless` flag for an album.
    public func setForceGapless(albumID: Int64, forced: Bool) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: "UPDATE albums SET force_gapless = ? WHERE id = ?",
                arguments: [forced ? 1 : 0, albumID]
            )
        }
        self.log.debug("album.forceGapless", ["id": albumID, "forced": forced])
    }

    /// Toggles the `excluded_from_shuffle` flag for an album and all its tracks.
    public func setExcludedFromShuffle(albumID: Int64, excluded: Bool) async throws {
        try await self.database.write { db in
            try db.execute(
                sql: "UPDATE albums SET excluded_from_shuffle = ? WHERE id = ?",
                arguments: [excluded ? 1 : 0, albumID]
            )
            try db.execute(
                sql: "UPDATE tracks SET excluded_from_shuffle = ? WHERE album_id = ?",
                arguments: [excluded ? 1 : 0, albumID]
            )
        }
        self.log.debug("album.excludedFromShuffle", ["id": albumID, "excluded": excluded])
    }

    // MARK: - Read

    /// Fetches the album with `id`, or throws `.notFound` if absent.
    public func fetch(id: Int64) async throws -> Album {
        try await self.database.read { db in
            guard let album = try Album.fetchOne(db, key: id) else {
                throw PersistenceError.notFound(entity: "Album", id: id)
            }
            return album
        }
    }

    /// Returns the album matching `(title, albumArtistID)`, inserting a new row if none exists.
    ///
    /// Idempotent: concurrent calls with the same pair return the same row.
    public func findOrCreate(title: String, albumArtistID: Int64?) async throws -> Album {
        try await self.database.write { db in
            let existing = try Album
                .filter(Column("title") == title && Column("album_artist_id") == albumArtistID)
                .fetchOne(db)
            if let album = existing {
                return album
            }
            var album = Album(title: title, albumArtistID: albumArtistID)
            try album.insert(db)
            return album
        }
    }

    /// Fetches all albums, alphabetically by title.
    public func fetchAll() async throws -> [Album] {
        try await self.database.read { db in
            try Album.order(Column("title")).fetchAll(db)
        }
    }

    /// Returns the total album count.
    public func count() async throws -> Int {
        try await self.database.read { db in
            try Album.fetchCount(db)
        }
    }

    /// Returns a dictionary mapping album ID → non-disabled track count.
    public func fetchTrackCounts() async throws -> [Int64: Int] {
        try await self.database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT album_id, COUNT(*) AS cnt
                FROM tracks
                WHERE disabled = 0 AND album_id IS NOT NULL
                GROUP BY album_id
            """)
            var result: [Int64: Int] = [:]
            for row in rows {
                if let albumID: Int64 = row["album_id"] {
                    result[albumID] = row["cnt"]
                }
            }
            return result
        }
    }

    /// Returns a dictionary mapping artist ID → artist name.
    public func fetchArtistNameMap() async throws -> [Int64: String] {
        try await self.database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, name FROM artists")
            var result: [Int64: String] = [:]
            for row in rows {
                if let id: Int64 = row["id"], let name: String = row["name"] {
                    result[id] = name
                }
            }
            return result
        }
    }

    // MARK: - Search

    /// Full-text search across album title and artist name.
    ///
    /// Returns albums ranked by FTS5 relevance first, followed by any additional
    /// albums whose artist name matches the query (case-insensitive prefix).
    /// Returns an empty array for blank queries.
    public func search(query: String) async throws -> [Album] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        return try await self.database.read { db in
            var results = try SQL.albumsFTSQuery(trimmed).fetchAll(db)
            let seenIDs = Set(results.compactMap(\.id))
            let artistMatches = try SQL.albumsByArtistQuery(trimmed).fetchAll(db)
            results += artistMatches.filter { $0.id.map { !seenIDs.contains($0) } ?? true }
            return results
        }
    }

    /// Fetches all albums for a given artist ID (as album artist).
    public func fetchAll(albumArtistID: Int64) async throws -> [Album] {
        try await self.database.read { db in
            try Album
                .filter(Column("album_artist_id") == albumArtistID)
                .order(Column("year").desc, Column("title"))
                .fetchAll(db)
        }
    }
}
