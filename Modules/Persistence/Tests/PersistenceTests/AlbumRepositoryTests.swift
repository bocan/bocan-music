import Foundation
import Testing
@testable import Persistence

@Suite("Album Repository Tests")
struct AlbumRepositoryTests {
    private func makeDatabase() async throws -> Database {
        try await Database(location: .inMemory)
    }

    private func makeAlbum(
        title: String = "Test Album",
        artistID: Int64? = nil
    ) -> Album {
        Album(title: title, albumArtistID: artistID)
    }

    @Test("Insert and fetch round-trip")
    func insertAndFetch() async throws {
        let db = try await makeDatabase()
        let repo = AlbumRepository(database: db)
        let id = try await repo.insert(self.makeAlbum())
        let fetched = try await repo.fetch(id: id)
        #expect(fetched.id == id)
        #expect(fetched.title == "Test Album")
    }

    @Test("findOrCreate returns existing album on second call")
    func findOrCreateIdempotent() async throws {
        let db = try await makeDatabase()
        let repo = AlbumRepository(database: db)
        let first = try await repo.findOrCreate(title: "Abbey Road", albumArtistID: nil)
        let second = try await repo.findOrCreate(title: "Abbey Road", albumArtistID: nil)
        #expect(first.id == second.id)
    }

    @Test("Unique constraint: same (title, artist) throws on direct insert")
    func uniqueConstraintEnforced() async throws {
        let db = try await makeDatabase()
        let repo = AlbumRepository(database: db)
        let artistID = try await ArtistRepository(database: db).insert(Artist(name: "UniqueTest"))
        _ = try await repo.insert(self.makeAlbum(title: "Dup", artistID: artistID))
        await #expect(throws: (any Error).self) {
            _ = try await repo.insert(makeAlbum(title: "Dup", artistID: artistID))
        }
    }

    @Test("fetchAll returns albums alphabetically")
    func fetchAllAlphabetical() async throws {
        let db = try await makeDatabase()
        let repo = AlbumRepository(database: db)
        _ = try await repo.insert(Album(title: "Ziggy Stardust"))
        _ = try await repo.insert(Album(title: "Abbey Road"))
        let all = try await repo.fetchAll()
        #expect(all.first?.title == "Abbey Road")
    }

    @Test("count returns total album count")
    func countReturnsTotal() async throws {
        let db = try await makeDatabase()
        let repo = AlbumRepository(database: db)
        _ = try await repo.insert(Album(title: "Alpha"))
        _ = try await repo.insert(Album(title: "Beta"))
        let count = try await repo.count()
        #expect(count == 2)
    }

    @Test("Update persists changes")
    func updatePersistsChanges() async throws {
        let db = try await makeDatabase()
        let repo = AlbumRepository(database: db)
        let id = try await repo.insert(self.makeAlbum())
        var album = try await repo.fetch(id: id)
        album.year = 1969
        try await repo.update(album)
        let fetched = try await repo.fetch(id: id)
        #expect(fetched.year == 1969)
    }

    @Test("setForceGapless persists true flag")
    func setForceGaplessTrue() async throws {
        let db = try await makeDatabase()
        let repo = AlbumRepository(database: db)
        let id = try await repo.insert(self.makeAlbum())
        try await repo.setForceGapless(albumID: id, forced: true)
        let fetched = try await repo.fetch(id: id)
        #expect(fetched.forceGapless == true)
    }

    @Test("setForceGapless can toggle back to false")
    func setForceGaplessToggle() async throws {
        let db = try await makeDatabase()
        let repo = AlbumRepository(database: db)
        let id = try await repo.insert(self.makeAlbum())
        try await repo.setForceGapless(albumID: id, forced: true)
        try await repo.setForceGapless(albumID: id, forced: false)
        let fetched = try await repo.fetch(id: id)
        #expect(fetched.forceGapless == false)
    }

    @Test("forceGapless defaults to false on new album")
    func forceGaplessDefaultsFalse() async throws {
        let db = try await makeDatabase()
        let repo = AlbumRepository(database: db)
        let id = try await repo.insert(self.makeAlbum())
        let fetched = try await repo.fetch(id: id)
        #expect(fetched.forceGapless == false)
    }

    // MARK: - search(query:)

    @Test("search matches by album title via FTS")
    func searchMatchesByTitle() async throws {
        let db = try await makeDatabase()
        let repo = AlbumRepository(database: db)
        _ = try await repo.insert(Album(title: "Wall of Fire"))
        _ = try await repo.insert(Album(title: "Abbey Road"))
        let hits = try await repo.search(query: "fire")
        #expect(hits.map(\.title) == ["Wall of Fire"])
    }

    @Test("search matches by album-artist name")
    func searchMatchesByArtist() async throws {
        let db = try await makeDatabase()
        let albumRepo = AlbumRepository(database: db)
        let artistRepo = ArtistRepository(database: db)
        let arsonID = try await artistRepo.insert(Artist(name: "Arsonists"))
        _ = try await albumRepo.insert(Album(title: "Plain Title", albumArtistID: arsonID))
        let hits = try await albumRepo.search(query: "arson")
        #expect(hits.contains { $0.title == "Plain Title" })
    }

    @Test("search surfaces albums whose track titles match")
    func searchMatchesByTrackTitle() async throws {
        let db = try await makeDatabase()
        let albumRepo = AlbumRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        let albumID = try await albumRepo.insert(Album(title: "The Wall"))
        let now = Int64(Date().timeIntervalSince1970)
        _ = try await trackRepo.insert(
            Track(
                fileURL: "file:///tmp/\(UUID().uuidString).flac",
                fileSize: 1024,
                fileMtime: now,
                fileFormat: "flac",
                duration: 200,
                title: "Fire In The Sky",
                albumID: albumID,
                addedAt: now,
                updatedAt: now
            )
        )
        let hits = try await albumRepo.search(query: "fire")
        #expect(hits.contains { $0.id == albumID })
    }

    @Test("search dedupes albums matched by multiple passes")
    func searchDedupes() async throws {
        let db = try await makeDatabase()
        let albumRepo = AlbumRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        // Album title + track title both contain "fire" → only one row.
        let albumID = try await albumRepo.insert(Album(title: "Fire Album"))
        let now = Int64(Date().timeIntervalSince1970)
        _ = try await trackRepo.insert(
            Track(
                fileURL: "file:///tmp/\(UUID().uuidString).flac",
                fileSize: 1024,
                fileMtime: now,
                fileFormat: "flac",
                duration: 200,
                title: "Fire Song",
                albumID: albumID,
                addedAt: now,
                updatedAt: now
            )
        )
        let hits = try await albumRepo.search(query: "fire")
        #expect(hits.count { $0.id == albumID } == 1)
    }

    @Test("search returns empty for blank query")
    func searchBlankReturnsEmpty() async throws {
        let db = try await makeDatabase()
        let repo = AlbumRepository(database: db)
        _ = try await repo.insert(Album(title: "Anything"))
        #expect(try await repo.search(query: "   ").isEmpty)
        #expect(try await repo.search(query: "").isEmpty)
    }

    @Test("search excludes albums whose only matching track is disabled")
    func searchExcludesDisabledTracks() async throws {
        let db = try await makeDatabase()
        let albumRepo = AlbumRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        let albumID = try await albumRepo.insert(Album(title: "Quiet Album"))
        let now = Int64(Date().timeIntervalSince1970)
        var track = Track(
            fileURL: "file:///tmp/\(UUID().uuidString).flac",
            fileSize: 1024,
            fileMtime: now,
            fileFormat: "flac",
            duration: 200,
            title: "Fire Walk",
            albumID: albumID,
            addedAt: now,
            updatedAt: now
        )
        track.disabled = true
        _ = try await trackRepo.insert(track)
        let hits = try await albumRepo.search(query: "fire")
        #expect(hits.contains { $0.id == albumID } == false)
    }
}
