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

    // MARK: - Search

    /// Full-text search across album title field.
    ///
    /// Returns albums ranked by FTS5 relevance. Returns an empty array for blank queries.
    public func search(query: String) async throws -> [Album] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        return try await self.database.read { db in
            try SQL.albumsFTSQuery(trimmed).fetchAll(db)
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
