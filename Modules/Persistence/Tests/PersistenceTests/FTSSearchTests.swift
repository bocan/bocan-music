import Foundation
import Testing
@testable import Persistence

@Suite("FTS Search Tests")
struct FTSSearchTests {
    private func makeDatabase() async throws -> Database {
        try await Database(location: .inMemory)
    }

    private func insertTrack(
        db: Database,
        title: String,
        composer: String = "",
        genre: String = ""
    ) async throws {
        let now = Int64(Date().timeIntervalSince1970)
        let track = Track(
            fileURL: "file:///tmp/\(title.hashValue).flac",
            fileSize: 1024,
            fileMtime: now,
            fileFormat: "flac",
            duration: 200,
            title: title,
            genre: genre.isEmpty ? nil : genre,
            composer: composer.isEmpty ? nil : composer,
            addedAt: now,
            updatedAt: now
        )
        let repo = TrackRepository(database: db)
        _ = try await repo.insert(track)
    }

    @Test("FTS query matches exact title")
    func ftsMatchesExactTitle() async throws {
        let db = try await makeDatabase()
        try await insertTrack(db: db, title: "Bohemian Rhapsody")
        let results = try await db.read { grdb in
            try SQL.tracksFTSQuery("Bohemian").fetchAll(grdb)
        }
        #expect(results.count == 1)
        #expect(results.first?.title == "Bohemian Rhapsody")
    }

    @Test("FTS removes diacritics: 'bjork' matches 'Björk'")
    func ftsRemovesDiacriticsBjork() async throws {
        let db = try await makeDatabase()
        try await insertTrack(db: db, title: "Björk")
        let results = try await db.read { grdb in
            try SQL.tracksFTSQuery("bjork").fetchAll(grdb)
        }
        #expect(results.count == 1)
    }

    @Test("FTS removes diacritics: 'sigur ros' matches 'Sigur Rós'")
    func ftsRemovesDiacriticsSigurRos() async throws {
        let db = try await makeDatabase()
        try await insertTrack(db: db, title: "Ára bátur", composer: "Sigur Rós")
        let results = try await db.read { grdb in
            try SQL.tracksFTSQuery("sigur ros").fetchAll(grdb)
        }
        #expect(results.count == 1)
    }

    @Test("FTS removes diacritics: 'motorhead' matches 'Motörhead'")
    func ftsRemovesDiacriticsMotorhead() async throws {
        let db = try await makeDatabase()
        try await insertTrack(db: db, title: "Ace of Spades", genre: "Motörhead")
        let results = try await db.read { grdb in
            try SQL.tracksFTSQuery("motorhead").fetchAll(grdb)
        }
        #expect(results.count == 1)
    }

    @Test("FTS stays in sync after update")
    func ftsInSyncAfterUpdate() async throws {
        let db = try await makeDatabase()
        try await insertTrack(db: db, title: "Original Title")
        let repo = TrackRepository(database: db)
        let tracks = try await repo.fetchAll()
        var track = try #require(tracks.first)
        track.title = "Updated Title"
        try await repo.update(track)
        // Old title should no longer match
        let oldResults = try await db.read { grdb in
            try SQL.tracksFTSQuery("Original").fetchAll(grdb)
        }
        #expect(oldResults.isEmpty)
        // New title should match
        let newResults = try await db.read { grdb in
            try SQL.tracksFTSQuery("Updated").fetchAll(grdb)
        }
        #expect(newResults.count == 1)
    }

    @Test("FTS stays in sync after delete")
    func ftsInSyncAfterDelete() async throws {
        let db = try await makeDatabase()
        try await insertTrack(db: db, title: "Deleted Song")
        let repo = TrackRepository(database: db)
        let allTracks = try await repo.fetchAll()
        let track = try #require(allTracks.first)
        let id = try #require(track.id)
        try await repo.delete(id: id)
        let results = try await db.read { grdb in
            try SQL.tracksFTSQuery("Deleted").fetchAll(grdb)
        }
        #expect(results.isEmpty)
    }

    @Test("SQL injection via FTS term leaves table intact")
    func ftsInjectionSafe() async throws {
        let db = try await makeDatabase()
        try await insertTrack(db: db, title: "Safe Track")
        let malicious = "'; DROP TABLE tracks; --"
        // Should return zero results and NOT throw
        let results = try await db.read { grdb in
            try SQL.tracksFTSQuery(malicious).fetchAll(grdb)
        }
        #expect(results.isEmpty)
        // Table should still exist
        let repo = TrackRepository(database: db)
        let count = try await repo.count()
        #expect(count == 1)
    }

    @Test("Artist FTS matches name")
    func artistFTSMatchesName() async throws {
        let db = try await makeDatabase()
        let artistRepo = ArtistRepository(database: db)
        _ = try await artistRepo.insert(Artist(name: "The Beatles"))
        let results = try await db.read { grdb in
            try SQL.artistsFTSQuery("Beatles").fetchAll(grdb)
        }
        #expect(results.count == 1)
    }

    @Test("Album FTS matches title")
    func albumFTSMatchesTitle() async throws {
        let db = try await makeDatabase()
        let albumRepo = AlbumRepository(database: db)
        _ = try await albumRepo.insert(Album(title: "Abbey Road"))
        let results = try await db.read { grdb in
            try SQL.albumsFTSQuery("Abbey").fetchAll(grdb)
        }
        #expect(results.count == 1)
    }

    @Test("Renaming an artist updates tracks_fts.artist_name (audit #3)")
    func renamingArtistRefreshesTrackFTS() async throws {
        let db = try await makeDatabase()
        let artistRepo = ArtistRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        var artist = try await artistRepo.findOrCreate(name: "Old Name")
        guard let artistID = artist.id else {
            Issue.record("findOrCreate did not yield an id")
            return
        }
        let now = Int64(Date().timeIntervalSince1970)
        var track = Track(
            fileURL: "file:///tmp/rename-fts.flac",
            fileSize: 1,
            fileMtime: now,
            fileFormat: "flac",
            duration: 1,
            title: "Some Song",
            addedAt: now,
            updatedAt: now
        )
        track.artistID = artistID
        _ = try await trackRepo.insert(track)

        // Pre-rename: search by old artist name finds the track.
        let pre = try await db.read { grdb in
            try SQL.tracksFTSQuery("Old Name").fetchAll(grdb)
        }
        #expect(pre.count == 1)

        // Rename the artist.
        artist.name = "Brand New Name"
        try await artistRepo.update(artist)

        // Post-rename: old name is gone, new name resolves.
        let oldHits = try await db.read { grdb in
            try SQL.tracksFTSQuery("Old Name").fetchAll(grdb)
        }
        #expect(oldHits.isEmpty)
        let newHits = try await db.read { grdb in
            try SQL.tracksFTSQuery("Brand New").fetchAll(grdb)
        }
        #expect(newHits.count == 1)
    }

    @Test("Renaming an album updates tracks_fts.album_title (audit #3)")
    func renamingAlbumRefreshesTrackFTS() async throws {
        let db = try await makeDatabase()
        let albumRepo = AlbumRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        let albumID = try await albumRepo.insert(Album(title: "Old Album"))
        let now = Int64(Date().timeIntervalSince1970)
        var track = Track(
            fileURL: "file:///tmp/rename-album-fts.flac",
            fileSize: 1,
            fileMtime: now,
            fileFormat: "flac",
            duration: 1,
            title: "Track One",
            addedAt: now,
            updatedAt: now
        )
        track.albumID = albumID
        _ = try await trackRepo.insert(track)

        let pre = try await db.read { grdb in
            try SQL.tracksFTSQuery("Old Album").fetchAll(grdb)
        }
        #expect(pre.count == 1)

        var album = try #require(
            try await db.read { grdb in
                try Album.fetchOne(grdb, key: albumID)
            }
        )
        album.title = "Renamed Album"
        try await albumRepo.update(album)

        let oldHits = try await db.read { grdb in
            try SQL.tracksFTSQuery("Old Album").fetchAll(grdb)
        }
        #expect(oldHits.isEmpty)
        let newHits = try await db.read { grdb in
            try SQL.tracksFTSQuery("Renamed").fetchAll(grdb)
        }
        #expect(newHits.count == 1)
    }
}
