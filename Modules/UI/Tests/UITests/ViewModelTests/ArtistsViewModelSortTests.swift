import Foundation
import Testing
@testable import Persistence
@testable import UI

// MARK: - ArtistsViewModelSortTests

// `.serialized`: setSortOrder writes a shared UserDefaults key, so running the
// sort/persistence cases in parallel could let one test's write leak into
// another's view-model init.
@Suite("ArtistsViewModel Sort Tests", .serialized)
@MainActor
struct ArtistsViewModelSortTests {
    private func makeDatabase() async throws -> Database {
        try await Database(location: .inMemory)
    }

    /// Seeds three artists with distinct album and song counts so each sort order
    /// produces a different ordering:
    ///   Alpha: 1 album,  1 song
    ///   Mu:    1 album,  2 songs
    ///   Zeta:  2 albums, 3 songs
    private func seed(_ db: Database) async throws {
        try await db.write { db in
            func artist(_ name: String) throws -> Int64 {
                var record = Artist(name: name)
                try record.insert(db)
                return try #require(record.id)
            }
            func album(_ title: String, artistID: Int64) throws -> Int64 {
                var record = Album(title: title, albumArtistID: artistID)
                try record.insert(db)
                return try #require(record.id)
            }
            func track(_ title: String, artistID: Int64, albumID: Int64) throws {
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
                try t.insert(db)
            }

            let alpha = try artist("Alpha")
            let mu = try artist("Mu")
            let zeta = try artist("Zeta")

            let alphaAlbum = try album("A1", artistID: alpha)
            try track("a1", artistID: alpha, albumID: alphaAlbum)

            let muAlbum = try album("M1", artistID: mu)
            try track("m1", artistID: mu, albumID: muAlbum)
            try track("m2", artistID: mu, albumID: muAlbum)

            let zetaAlbum1 = try album("Z1", artistID: zeta)
            let zetaAlbum2 = try album("Z2", artistID: zeta)
            try track("z1", artistID: zeta, albumID: zetaAlbum1)
            try track("z2", artistID: zeta, albumID: zetaAlbum2)
            try track("z3", artistID: zeta, albumID: zetaAlbum2)
        }
    }

    @Test("artistName sort orders alphabetically by name")
    func sortByArtistName() async throws {
        let db = try await makeDatabase()
        try await self.seed(db)
        let vm = ArtistsViewModel(repository: ArtistRepository(database: db))
        await vm.load()
        vm.setSortOrder(.artistName)
        #expect(vm.artists.map(\.name) == ["Alpha", "Mu", "Zeta"])
    }

    @Test("albumCount sort orders by album count, then artist name")
    func sortByAlbumCount() async throws {
        let db = try await makeDatabase()
        try await self.seed(db)
        let vm = ArtistsViewModel(repository: ArtistRepository(database: db))
        await vm.load()
        vm.setSortOrder(.albumCount)
        // Zeta (2 albums) first; Alpha and Mu tie at 1, so artist name breaks it.
        #expect(vm.artists.map(\.name) == ["Zeta", "Alpha", "Mu"])
    }

    @Test("songCount sort orders by song count, most first")
    func sortBySongCount() async throws {
        let db = try await makeDatabase()
        try await self.seed(db)
        let vm = ArtistsViewModel(repository: ArtistRepository(database: db))
        await vm.load()
        vm.setSortOrder(.songCount)
        #expect(vm.artists.map(\.name) == ["Zeta", "Mu", "Alpha"])
    }

    @Test("sort order is persisted and restored by a fresh view model")
    func sortOrderPersists() async throws {
        let key = ArtistsViewModel.sortOrderKey
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: key)
        defer { defaults.removeObject(forKey: key) }

        let db = try await makeDatabase()
        let repo = ArtistRepository(database: db)

        let first = ArtistsViewModel(repository: repo)
        #expect(first.sortOrder == .artistName) // default with a clean key
        first.setSortOrder(.songCount)

        // A new instance (next launch) reads the persisted preference.
        let second = ArtistsViewModel(repository: repo)
        #expect(second.sortOrder == .songCount)
    }
}
