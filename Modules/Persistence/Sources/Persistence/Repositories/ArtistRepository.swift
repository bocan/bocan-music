import GRDB
import Observability

/// CRUD operations for the `artists` table.
public struct ArtistRepository: Sendable {
    // MARK: - Properties

    private let database: Database
    private let log = AppLogger.make(.persistence)

    // MARK: - Init

    /// Creates a repository backed by `database`.
    public init(database: Database) {
        self.database = database
    }

    // MARK: - Write

    /// Inserts `artist` and returns its new `id`.
    @discardableResult
    public func insert(_ artist: Artist) async throws -> Int64 {
        let id: Int64 = try await self.database.write { db in
            var mutable = artist
            try mutable.insert(db)
            guard let rowID = mutable.id else {
                throw PersistenceError.notFound(entity: "Artist", id: -1)
            }
            return rowID
        }
        self.log.debug("artist.insert", ["id": id])
        return id
    }

    /// Updates all columns of an existing `artist`.
    public func update(_ artist: Artist) async throws {
        guard let id = artist.id else { return }
        try await self.database.write { db in
            try artist.update(db)
        }
        self.log.debug("artist.update", ["id": id])
    }

    // MARK: - Read

    /// Fetches the artist with `id`, or throws `.notFound` if absent.
    public func fetch(id: Int64) async throws -> Artist {
        try await self.database.read { db in
            guard let artist = try Artist.fetchOne(db, key: id) else {
                throw PersistenceError.notFound(entity: "Artist", id: id)
            }
            return artist
        }
    }

    /// Fetches the artist whose `name` matches exactly, or `nil` if absent.
    public func fetchOne(name: String) async throws -> Artist? {
        try await self.database.read { db in
            try Artist.filter(Column("name") == name).fetchOne(db)
        }
    }

    /// Returns the artist matching `name`, inserting a new row if none exists.
    ///
    /// This is idempotent: concurrent calls with the same name return the same row.
    public func findOrCreate(name: String) async throws -> Artist {
        try await self.database.write { db in
            if let existing = try Artist.filter(Column("name") == name).fetchOne(db) {
                return existing
            }
            var artist = Artist(name: name)
            try artist.insert(db)
            return artist
        }
    }

    /// Fetches all artists, alphabetically.
    public func fetchAll() async throws -> [Artist] {
        try await self.database.read { db in
            try Artist.order(Column("sort_name"), Column("name")).fetchAll(db)
        }
    }

    /// Returns a dictionary mapping artist ID → album count (as album artist).
    ///
    /// Only counts non-disabled albums. Artists with no albums are absent from the result.
    public func fetchAlbumCounts() async throws -> [Int64: Int] {
        try await self.database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT album_artist_id, COUNT(*) AS cnt
                FROM albums
                WHERE album_artist_id IS NOT NULL
                GROUP BY album_artist_id
            """)
            var counts: [Int64: Int] = [:]
            for row in rows {
                if let id: Int64 = row["album_artist_id"], let cnt: Int = row["cnt"] {
                    counts[id] = cnt
                }
            }
            return counts
        }
    }

    // MARK: - Search

    /// Full-text search across artist name field.
    ///
    /// Returns artists ranked by FTS5 relevance. Returns an empty array for blank queries.
    public func search(query: String) async throws -> [Artist] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        return try await self.database.read { db in
            try SQL.artistsFTSQuery(trimmed).fetchAll(db)
        }
    }
}
