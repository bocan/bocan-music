import Foundation
import Testing
@testable import Persistence

@Suite("CoverArtRepository")
struct CoverArtRepositoryTests {
    private func makeDB() async throws -> Database {
        try await Database(location: .inMemory)
    }

    @Test("save inserts new row and returns its path")
    func saveNew() async throws {
        let db = try await makeDB()
        let repo = CoverArtRepository(database: db)
        let art = CoverArt(hash: "h1", path: "/img/h1.jpg", width: 100, height: 100, format: "jpg")
        let path = try await repo.save(art)
        #expect(path == "/img/h1.jpg")
        let fetched = try await repo.fetch(hash: "h1")
        #expect(fetched?.path == "/img/h1.jpg")
        #expect(fetched?.width == 100)
    }

    @Test("save is a no-op when hash already exists and returns stored path")
    func saveExisting() async throws {
        let db = try await makeDB()
        let repo = CoverArtRepository(database: db)
        _ = try await repo.save(CoverArt(hash: "h1", path: "/img/h1.jpg"))
        let path = try await repo.save(CoverArt(hash: "h1", path: "/img/other.jpg"))
        #expect(path == "/img/h1.jpg")
    }

    @Test("delete removes the row")
    func deleteRow() async throws {
        let db = try await makeDB()
        let repo = CoverArtRepository(database: db)
        _ = try await repo.save(CoverArt(hash: "h1", path: "/p"))
        try await repo.delete(hash: "h1")
        #expect(try await repo.fetch(hash: "h1") == nil)
    }

    @Test("fetch returns nil for unknown hash")
    func fetchMissing() async throws {
        let db = try await makeDB()
        let repo = CoverArtRepository(database: db)
        #expect(try await repo.fetch(hash: "ghost") == nil)
    }
}
