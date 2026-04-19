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
}
