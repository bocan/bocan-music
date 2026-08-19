import Foundation
import Testing
@testable import Persistence

@Suite("MaintenanceRepository")
struct MaintenanceRepositoryTests {
    private func makeDB() async throws -> Database {
        try await Database(location: .inMemory)
    }

    /// Inserts one artist, album, and track through the repositories so the
    /// FTS triggers populate the indexes normally.
    private func seed(_ db: Database) async throws -> Int64 {
        let artist = try await ArtistRepository(database: db).findOrCreate(name: "Ulrich Schnauss")
        let album = try await AlbumRepository(database: db)
            .findOrCreate(title: "A Strangely Isolated Place", albumArtistID: artist.id)
        let now = Int64(Date().timeIntervalSince1970)
        return try await TrackRepository(database: db).insert(Track(
            fileURL: "file:///m/monday.flac",
            fileSize: 1,
            fileMtime: now,
            fileFormat: "flac",
            duration: 300,
            title: "Monday - Paracetamol",
            artistID: artist.id,
            albumID: album.id,
            addedAt: now,
            updatedAt: now
        ))
    }

    private func ftsHits(_ db: Database, table: String, term: String) async throws -> Int {
        try await db.read { dbc in
            try Int.fetchOne(
                dbc, sql: "SELECT COUNT(*) FROM \(table) WHERE \(table) MATCH ?", arguments: [term]
            ) ?? 0
        }
    }

    @Test("rebuild repopulates gutted indexes from source tables")
    func rebuildRepairsGuttedIndexes() async throws {
        let db = try await makeDB()
        _ = try await self.seed(db)

        // Simulate the damage the button exists for: FTS rows gone while the
        // source tables are intact (hand edits, corruption remediation).
        try await db.write { dbc in
            try dbc.execute(sql: "DELETE FROM tracks_fts")
            try dbc.execute(sql: "DELETE FROM artists_fts")
            try dbc.execute(sql: "DELETE FROM albums_fts")
        }
        #expect(try await self.ftsHits(db, table: "tracks_fts", term: "monday") == 0)

        let counts = try await MaintenanceRepository(database: db).rebuildFTSIndexes()
        #expect(counts == MaintenanceRepository.FTSRebuildCounts(tracks: 1, artists: 1, albums: 1))
        #expect(try await self.ftsHits(db, table: "tracks_fts", term: "monday") == 1)
        #expect(try await self.ftsHits(db, table: "artists_fts", term: "ulrich") == 1)
        #expect(try await self.ftsHits(db, table: "albums_fts", term: "isolated") == 1)
    }

    @Test("rebuild replaces stale denormalised names with source truth")
    func rebuildFixesStaleDenormalisedRows() async throws {
        let db = try await makeDB()
        let trackID = try await self.seed(db)

        // Plant a stale artist name in the track index (the pre-M014 bug
        // class: the source changed, the denormalised FTS copy did not).
        try await db.write { dbc in
            try dbc.execute(sql: "DELETE FROM tracks_fts WHERE rowid = ?", arguments: [trackID])
            try dbc.execute(
                sql: """
                INSERT INTO tracks_fts(rowid, title, composer, genre, artist_name, album_title)
                VALUES (?, 'Monday - Paracetamol', '', '', 'Wrong Artist', 'Wrong Album')
                """,
                arguments: [trackID]
            )
        }
        #expect(try await self.ftsHits(db, table: "tracks_fts", term: "wrong") == 1)

        _ = try await MaintenanceRepository(database: db).rebuildFTSIndexes()
        #expect(try await self.ftsHits(db, table: "tracks_fts", term: "wrong") == 0)
        #expect(try await self.ftsHits(db, table: "tracks_fts", term: "ulrich") == 1)
    }

    @Test("rebuild of an empty library reports zero counts")
    func rebuildEmptyLibrary() async throws {
        let db = try await makeDB()
        let counts = try await MaintenanceRepository(database: db).rebuildFTSIndexes()
        #expect(counts.total == 0)
    }
}
