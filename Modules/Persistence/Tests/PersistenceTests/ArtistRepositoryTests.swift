import Foundation
import Testing
@testable import Persistence

@Suite("ArtistRepository")
struct ArtistRepositoryTests {
    private func makeDB() async throws -> Database {
        try await Database(location: .inMemory)
    }

    @discardableResult
    private func seedTrack(
        _ db: Database,
        title: String,
        artistID: Int64?,
        albumID: Int64?,
        disabled: Bool = false
    ) async throws -> Int64 {
        try await db.write { db in
            var t = Track(
                fileURL: "file:///tmp/\(title).mp3",
                fileSize: 1,
                fileMtime: 0,
                fileFormat: "mp3",
                duration: 1,
                title: title,
                addedAt: 0,
                updatedAt: 0
            )
            t.artistID = artistID
            t.albumID = albumID
            t.disabled = disabled
            try t.insert(db)
            return try #require(t.id)
        }
    }

    private func seedArtist(_ db: Database, name: String) async throws -> Int64 {
        try await db.write { db in
            var artist = Artist(name: name)
            try artist.insert(db)
            return try #require(artist.id)
        }
    }

    private func seedAlbum(_ db: Database, title: String, albumArtistID: Int64?) async throws -> Int64 {
        try await db.write { db in
            var album = Album(title: title, albumArtistID: albumArtistID)
            try album.insert(db)
            return try #require(album.id)
        }
    }

    @Test("fetchAlbumArtistIDs includes artists credited as an album artist")
    func includesAlbumArtists() async throws {
        let db = try await makeDB()
        let headliner = try await seedArtist(db, name: "Headliner")
        let album = try await seedAlbum(db, title: "LP", albumArtistID: headliner)
        try await self.seedTrack(db, title: "t1", artistID: headliner, albumID: album)

        let ids = try await ArtistRepository(database: db).fetchAlbumArtistIDs()
        #expect(ids == [headliner])
    }

    @Test("fetchAlbumArtistIDs excludes artists with only per-track credits")
    func excludesGuestArtists() async throws {
        let db = try await makeDB()
        let headliner = try await seedArtist(db, name: "Headliner")
        let guest = try await seedArtist(db, name: "Guest")
        let album = try await seedAlbum(db, title: "LP", albumArtistID: headliner)
        // The guest sings a track on the headliner's album but fronts no album.
        try await self.seedTrack(db, title: "t1", artistID: headliner, albumID: album)
        try await self.seedTrack(db, title: "t2 (feat. Guest)", artistID: guest, albumID: album)

        let ids = try await ArtistRepository(database: db).fetchAlbumArtistIDs()
        #expect(ids.contains(headliner))
        #expect(!ids.contains(guest))
    }

    @Test("fetchAlbumArtistIDs ignores compilations with no album artist")
    func ignoresCompilations() async throws {
        let db = try await makeDB()
        let contributor = try await seedArtist(db, name: "Contributor")
        // A "Various Artists" compilation: album_artist_id is NULL by design.
        let compilation = try await seedAlbum(db, title: "Now That's Music", albumArtistID: nil)
        try await self.seedTrack(db, title: "t1", artistID: contributor, albumID: compilation)

        let ids = try await ArtistRepository(database: db).fetchAlbumArtistIDs()
        #expect(ids.isEmpty)
    }

    @Test("fetchAlbumArtistIDs excludes albums whose tracks are all disabled")
    func excludesFullyDisabledAlbums() async throws {
        let db = try await makeDB()
        let headliner = try await seedArtist(db, name: "Headliner")
        let album = try await seedAlbum(db, title: "Vanished LP", albumArtistID: headliner)
        try await self.seedTrack(db, title: "t1", artistID: headliner, albumID: album, disabled: true)

        let ids = try await ArtistRepository(database: db).fetchAlbumArtistIDs()
        #expect(ids.isEmpty)
    }
}
