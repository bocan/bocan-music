import Foundation
import Testing
@testable import Persistence

@Suite("SubsonicServerRepository", .serialized)
struct SubsonicServerRepositoryTests {
    private func makeDB() async throws -> Database {
        try await Database(location: .inMemory)
    }

    private func sample(name: String = "Home", sortIndex: Int = 0) -> SubsonicServerDTO {
        SubsonicServerDTO(
            name: name,
            serverURL: URL(string: "https://music.example.test")!, // swiftlint:disable:this force_unwrapping
            authKind: "tokenSalt",
            username: "user",
            keychainAccount: "subsonic.\(name)",
            sortIndex: sortIndex,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    @Test("insert then fetch returns the same DTO")
    func insertAndFetch() async throws {
        let db = try await makeDB()
        let repo = SubsonicServerRepository(database: db)
        let dto = self.sample()
        try await repo.insert(dto)
        let fetched = try await repo.fetch(id: dto.id)
        #expect(fetched?.id == dto.id)
        #expect(fetched?.name == "Home")
        #expect(fetched?.serverURL.absoluteString == "https://music.example.test")
    }

    @Test("fetchAll orders by sort_index then created_at")
    func fetchAllOrdered() async throws {
        let db = try await makeDB()
        let repo = SubsonicServerRepository(database: db)
        try await repo.insert(self.sample(name: "B", sortIndex: 10))
        try await repo.insert(self.sample(name: "A", sortIndex: 1))
        let all = try await repo.fetchAll()
        #expect(all.map(\.name) == ["A", "B"])
    }

    @Test("update mutates persisted row")
    func updateRow() async throws {
        let db = try await makeDB()
        let repo = SubsonicServerRepository(database: db)
        var dto = self.sample()
        try await repo.insert(dto)
        dto.name = "Renamed"
        dto.precacheNext = false
        try await repo.update(dto)
        let fetched = try await repo.fetch(id: dto.id)
        #expect(fetched?.name == "Renamed")
        #expect(fetched?.precacheNext == false)
    }

    @Test("updateCapabilities writes only capabilities + last_connected_at")
    func updateCaps() async throws {
        let db = try await makeDB()
        let repo = SubsonicServerRepository(database: db)
        let dto = self.sample()
        try await repo.insert(dto)
        let payload = Data("{\"version\":\"1.16\"}".utf8)
        let connectedAt = Date(timeIntervalSince1970: 1_750_000_000)
        try await repo.updateCapabilities(id: dto.id, capabilitiesJSON: payload, lastConnectedAt: connectedAt)
        let fetched = try await repo.fetch(id: dto.id)
        #expect(fetched?.capabilitiesJSON == payload)
        #expect(fetched?.lastConnectedAt?.timeIntervalSince1970 == 1_750_000_000)
    }

    @Test("delete removes the row")
    func deleteRow() async throws {
        let db = try await makeDB()
        let repo = SubsonicServerRepository(database: db)
        let dto = self.sample()
        try await repo.insert(dto)
        try await repo.delete(id: dto.id)
        #expect(try await repo.fetch(id: dto.id) == nil)
    }

    @Test("metadata cache: upsert + fetch round-trip")
    func cacheRoundTrip() async throws {
        let db = try await makeDB()
        let repo = SubsonicServerRepository(database: db)
        let dto = self.sample()
        try await repo.insert(dto)
        let payload = Data("{\"id\":\"album-1\"}".utf8)
        try await repo.upsertCache(serverID: dto.id, entityKind: "album", entityID: "a1", payloadJSON: payload)
        let fetched = try await repo.fetchCache(serverID: dto.id, entityKind: "album", entityID: "a1")
        #expect(fetched == payload)
    }

    @Test("metadata cache: upsert replaces existing payload")
    func cacheUpsert() async throws {
        let db = try await makeDB()
        let repo = SubsonicServerRepository(database: db)
        let dto = self.sample()
        try await repo.insert(dto)
        try await repo.upsertCache(serverID: dto.id, entityKind: "album", entityID: "a1", payloadJSON: Data("a".utf8))
        try await repo.upsertCache(serverID: dto.id, entityKind: "album", entityID: "a1", payloadJSON: Data("b".utf8))
        #expect(try await repo.fetchCache(serverID: dto.id, entityKind: "album", entityID: "a1") == Data("b".utf8))
    }

    @Test("metadata cache: fetch returns nil for missing key")
    func cacheMiss() async throws {
        let db = try await makeDB()
        let repo = SubsonicServerRepository(database: db)
        let dto = self.sample()
        try await repo.insert(dto)
        #expect(try await repo.fetchCache(serverID: dto.id, entityKind: "album", entityID: "missing") == nil)
    }

    @Test("metadata cache: deleteCache clears all rows for a server")
    func cacheDelete() async throws {
        let db = try await makeDB()
        let repo = SubsonicServerRepository(database: db)
        let dto = self.sample()
        try await repo.insert(dto)
        try await repo.upsertCache(serverID: dto.id, entityKind: "album", entityID: "a1", payloadJSON: Data("x".utf8))
        try await repo.upsertCache(serverID: dto.id, entityKind: "song", entityID: "s1", payloadJSON: Data("y".utf8))
        try await repo.deleteCache(serverID: dto.id)
        #expect(try await repo.fetchCache(serverID: dto.id, entityKind: "album", entityID: "a1") == nil)
        #expect(try await repo.fetchCache(serverID: dto.id, entityKind: "song", entityID: "s1") == nil)
    }

    @Test("pruneStaleCache is a no-op when all entries are fresh")
    func pruneNoop() async throws {
        let db = try await makeDB()
        let repo = SubsonicServerRepository(database: db)
        let dto = self.sample()
        try await repo.insert(dto)
        try await repo.upsertCache(serverID: dto.id, entityKind: "album", entityID: "a1", payloadJSON: Data("x".utf8))
        try await repo.pruneStaleCache()
        #expect(try await repo.fetchCache(serverID: dto.id, entityKind: "album", entityID: "a1") != nil)
    }
}
