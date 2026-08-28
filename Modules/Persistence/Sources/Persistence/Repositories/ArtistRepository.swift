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
        try await self.database.fetchOne(Artist.self, id: id, entity: "Artist")
    }

    /// Fetches the artist whose `name` matches exactly, or `nil` if absent.
    public func fetchOne(name: String) async throws -> Artist? {
        try await self.database.read { db in
            try Artist.filter(Column("name") == name).fetchOne(db)
        }
    }

    /// Returns the artist matching `name`, inserting a new row if none exists,
    /// and fills in entity-level columns the caller learned from tags.
    ///
    /// `sortName` is the file's ARTISTSORT / ALBUMARTISTSORT. A tag value always
    /// wins over what is stored (tags are the source of truth and there is no
    /// artist-level editor); with no tag, a NULL `sort_name` is filled with
    /// `Artist.derivedSortName(from:)` so "The Beatles" files under B (#400).
    ///
    /// `musicbrainzID` fills a NULL `musicbrainz_artist_id` and is otherwise
    /// left alone: MBIDs are stable identifiers, so first-seen wins, and a
    /// later disagreement means two artists share a name (the disambiguation
    /// problem, #401), not that the stored value went stale (#399).
    ///
    /// This is idempotent: concurrent calls with the same name return the same row.
    public func findOrCreate(
        name: String,
        sortName: String? = nil,
        musicbrainzID: String? = nil
    ) async throws -> Artist {
        try await self.database.write { db in
            let taggedSort = sortName.flatMap { $0.isEmpty ? nil : $0 }
            let taggedMBID = musicbrainzID.flatMap { $0.isEmpty ? nil : $0 }
            if var existing = try Artist.filter(Column("name") == name).fetchOne(db) {
                var changed = false
                if existing.musicbrainzArtistID == nil, let taggedMBID {
                    existing.musicbrainzArtistID = taggedMBID
                    changed = true
                }
                if let taggedSort, existing.sortName != taggedSort {
                    existing.sortName = taggedSort
                    changed = true
                } else if taggedSort == nil, existing.sortName == nil,
                          let derived = Artist.derivedSortName(from: name) {
                    existing.sortName = derived
                    changed = true
                }
                if changed { try existing.update(db) }
                return existing
            }
            var artist = Artist(
                name: name,
                sortName: taggedSort ?? Artist.derivedSortName(from: name),
                musicbrainzArtistID: taggedMBID
            )
            try artist.insert(db)
            return artist
        }
    }

    /// Fetches all artists in sort-name order, falling back to the display
    /// name for rows with no sort name.
    public func fetchAll() async throws -> [Artist] {
        try await self.database.read { db in
            try Artist.fetchAll(
                db,
                sql: "SELECT * FROM artists ORDER BY COALESCE(sort_name, name) COLLATE NOCASE, name COLLATE NOCASE"
            )
        }
    }

    /// Returns a dictionary mapping artist ID → album count.
    ///
    /// Counts distinct albums that contain at least one non-disabled track by this artist,
    /// regardless of who the album artist is.  This correctly handles compilation albums
    /// where the album artist is "Various Artists" but individual tracks have a real artist.
    public func fetchAlbumCounts() async throws -> [Int64: Int] {
        try await self.database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT artist_id, COUNT(DISTINCT album_id) AS cnt
                FROM tracks
                WHERE disabled = 0 AND artist_id IS NOT NULL AND album_id IS NOT NULL
                GROUP BY artist_id
            """)
            var counts: [Int64: Int] = [:]
            for row in rows {
                if let id: Int64 = row["artist_id"], let cnt: Int = row["cnt"] {
                    counts[id] = cnt
                }
            }
            return counts
        }
    }

    /// Returns a dictionary mapping artist ID → enabled track count.
    ///
    /// Only counts non-disabled tracks. Artists with no tracks are absent from the result.
    public func fetchTrackCounts() async throws -> [Int64: Int] {
        try await self.database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT artist_id, COUNT(*) AS cnt
                FROM tracks
                WHERE disabled = 0 AND artist_id IS NOT NULL
                GROUP BY artist_id
            """)
            var counts: [Int64: Int] = [:]
            for row in rows {
                if let id: Int64 = row["artist_id"], let cnt: Int = row["cnt"] {
                    counts[id] = cnt
                }
            }
            return counts
        }
    }

    /// Returns the IDs of artists credited as the album artist of at least one
    /// album containing an enabled track. Backs the Artists list's "Album
    /// Artists" scope (#369): guest and per-track-credit artists appear in the
    /// full list but are absent here. Compilations without a single album
    /// artist (`album_artist_id IS NULL`) contribute nothing; they stay
    /// reachable through the Albums grid's "Various Artists" grouping.
    public func fetchAlbumArtistIDs() async throws -> Set<Int64> {
        try await self.database.read { db in
            let ids = try Int64.fetchAll(db, sql: """
                SELECT DISTINCT albums.album_artist_id
                FROM albums
                JOIN tracks ON tracks.album_id = albums.id AND tracks.disabled = 0
                WHERE albums.album_artist_id IS NOT NULL
            """)
            return Set(ids)
        }
    }

    // MARK: - MusicBrainz enrichment (#401)

    /// Artists with an MBID that have never been looked up, oldest id first.
    public func fetchNeedingEnrichment(limit: Int) async throws -> [Artist] {
        try await self.database.read { db in
            try Artist
                .filter(Column("musicbrainz_artist_id") != nil)
                .filter(Column("musicbrainz_fetched_at") == nil)
                .order(Column("id"))
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// How many artists still await a MusicBrainz lookup.
    public func countNeedingEnrichment() async throws -> Int {
        try await self.database.read { db in
            try Artist
                .filter(Column("musicbrainz_artist_id") != nil)
                .filter(Column("musicbrainz_fetched_at") == nil)
                .fetchCount(db)
        }
    }

    /// Stores what a MusicBrainz lookup returned and stamps `fetched_at`.
    /// `sortName` is applied only when the row has none (tags and the
    /// derivation win over MusicBrainz's sort name); an empty
    /// `disambiguation` is stored as NULL.
    public func setEnrichment(id: Int64, disambiguation: String?, sortName: String?, fetchedAt: Int64) async throws {
        let cleaned = disambiguation.flatMap { $0.isEmpty ? nil : $0 }
        try await self.database.write { db in
            try db.execute(
                sql: """
                UPDATE artists
                   SET disambiguation = ?,
                       sort_name = COALESCE(sort_name, ?),
                       musicbrainz_fetched_at = ?
                 WHERE id = ?
                """,
                arguments: [cleaned, sortName, fetchedAt, id]
            )
        }
        self.log.debug("artist.enriched", ["id": id, "disambiguation": cleaned as Any])
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
