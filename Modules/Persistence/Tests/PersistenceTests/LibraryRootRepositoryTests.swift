import Foundation
import Testing
@testable import Persistence

@Suite("LibraryRootRepository")
struct LibraryRootRepositoryTests {
    private func makeDB() async throws -> Database {
        try await Database(location: .inMemory)
    }

    private func sample(path: String) -> LibraryRoot {
        LibraryRoot(path: path, bookmark: Data([0x01, 0x02]), addedAt: 1_700_000_000)
    }

    @Test("upsert inserts a new row and fetch returns it")
    func upsertAndFetch() async throws {
        let db = try await makeDB()
        let repo = LibraryRootRepository(database: db)
        let saved = try await repo.upsert(self.sample(path: "/Music"))
        let all = try await repo.fetchAll()
        #expect(all.count == 1)
        #expect(all.first?.path == "/Music")
        let byID = try await repo.fetch(id: #require(saved.id))
        #expect(byID.path == "/Music")
    }

    @Test("markInaccessible flips the flag")
    func markInaccessible() async throws {
        let db = try await makeDB()
        let repo = LibraryRootRepository(database: db)
        let saved = try await repo.upsert(self.sample(path: "/A"))
        try await repo.markInaccessible(id: #require(saved.id), true)
        let fetched = try await repo.fetch(id: #require(saved.id))
        #expect(fetched.isInaccessible == true)
    }

    @Test("delete removes the row")
    func deleteRow() async throws {
        let db = try await makeDB()
        let repo = LibraryRootRepository(database: db)
        let saved = try await repo.upsert(self.sample(path: "/A"))
        try await repo.delete(id: #require(saved.id))
        let all = try await repo.fetchAll()
        #expect(all.isEmpty)
    }

    @Test("fetch throws notFound for unknown id")
    func fetchMissing() async throws {
        let db = try await makeDB()
        let repo = LibraryRootRepository(database: db)
        await #expect(throws: (any Error).self) {
            _ = try await repo.fetch(id: 9999)
        }
    }
}
