import Foundation
import Testing
@testable import Persistence

@Suite("JellyfinServerRepository", .serialized)
struct JellyfinServerRepositoryTests {
    private func makeDB() async throws -> Database {
        try await Database(location: .inMemory)
    }

    private func sample(name: String = "Home", sortIndex: Int = 0) -> JellyfinServerDTO {
        JellyfinServerDTO(
            name: name,
            serverURL: URL(string: "https://jellyfin.example.test") ?? URL(filePath: "/"),
            userID: "7f3b1c0e9d2a4e5f8a6b0c1d2e3f4a5b",
            username: "listener",
            deviceID: "0F5C2A6E-8E0B-4C55-9C1E-3B7D2A9E4F10",
            sortIndex: sortIndex,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    /// Writes a cache row with an explicit age, because `upsertCache` always stamps "now".
    private func insertCacheRow(
        _ db: Database,
        serverID: UUID,
        entityID: String,
        fetchedAt: Date
    ) async throws {
        try await db.write { grdb in
            try grdb.execute(
                sql: """
                INSERT INTO jellyfin_metadata_cache
                    (server_id, entity_kind, entity_id, payload_json, fetched_at)
                VALUES (?, 'album', ?, ?, ?)
                """,
                arguments: [serverID.uuidString, entityID, Data("x".utf8), fetchedAt.timeIntervalSince1970]
            )
        }
    }

    private func cacheRowCount(_ db: Database) async throws -> Int {
        try await db.read { grdb in
            try Int.fetchOne(grdb, sql: "SELECT COUNT(*) FROM jellyfin_metadata_cache") ?? -1
        }
    }

    @Test("insert then fetch returns every non-default field")
    func insertAndFetch() async throws {
        let db = try await makeDB()
        let repo = JellyfinServerRepository(database: db)
        let dto = JellyfinServerDTO(
            name: "Studio",
            serverURL: URL(string: "https://studio.example.test:8920") ?? URL(filePath: "/"),
            userID: "a1b2c3d4e5f60718293a4b5c6d7e8f90",
            username: "chris",
            deviceID: "DEVICE-ID-1",
            allowSelfSignedTLS: true,
            maxBitrate: "192",
            preferredFormat: "opus",
            precacheNext: false,
            includeInSearch: false,
            showInSidebar: false,
            scrobble: false,
            syncStars: false,
            sortIndex: 7,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastConnectedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
        try await repo.insert(dto)
        let fetched = try #require(try await repo.fetch(id: dto.id))
        #expect(fetched.id == dto.id)
        #expect(fetched.name == "Studio")
        #expect(fetched.serverURL.absoluteString == "https://studio.example.test:8920")
        #expect(fetched.userID == "a1b2c3d4e5f60718293a4b5c6d7e8f90")
        #expect(fetched.username == "chris")
        #expect(fetched.deviceID == "DEVICE-ID-1")
        #expect(fetched.allowSelfSignedTLS)
        #expect(fetched.maxBitrate == "192")
        #expect(fetched.preferredFormat == "opus")
        #expect(fetched.precacheNext == false)
        #expect(fetched.includeInSearch == false)
        #expect(fetched.showInSidebar == false)
        #expect(fetched.scrobble == false)
        #expect(fetched.syncStars == false)
        #expect(fetched.sortIndex == 7)
        #expect(fetched.createdAt.timeIntervalSince1970 == 1_700_000_000)
        #expect(fetched.lastConnectedAt?.timeIntervalSince1970 == 1_750_000_000)
    }

    @Test("defaults match the Subsonic table")
    func defaults() async throws {
        let db = try await makeDB()
        let repo = JellyfinServerRepository(database: db)
        let dto = self.sample()
        try await repo.insert(dto)
        let fetched = try #require(try await repo.fetch(id: dto.id))
        #expect(fetched.allowSelfSignedTLS == false)
        #expect(fetched.maxBitrate == "original")
        #expect(fetched.preferredFormat == "original")
        #expect(fetched.precacheNext)
        #expect(fetched.includeInSearch)
        #expect(fetched.showInSidebar)
        #expect(fetched.scrobble)
        #expect(fetched.syncStars)
        #expect(fetched.lastConnectedAt == nil)
    }

    @Test("fetchAll orders by sort_index then created_at")
    func fetchAllOrdered() async throws {
        let db = try await makeDB()
        let repo = JellyfinServerRepository(database: db)
        try await repo.insert(self.sample(name: "B", sortIndex: 10))
        try await repo.insert(self.sample(name: "A", sortIndex: 1))
        let all = try await repo.fetchAll()
        #expect(all.map(\.name) == ["A", "B"])
    }

    @Test("server name is unique")
    func uniqueName() async throws {
        let db = try await makeDB()
        let repo = JellyfinServerRepository(database: db)
        try await repo.insert(self.sample(name: "Home"))
        await #expect(throws: (any Error).self) {
            try await repo.insert(self.sample(name: "Home"))
        }
        #expect(try await repo.fetchAll().count == 1)
    }

    @Test("update mutates the persisted row")
    func updateRow() async throws {
        let db = try await makeDB()
        let repo = JellyfinServerRepository(database: db)
        var dto = self.sample()
        try await repo.insert(dto)
        dto.name = "Renamed"
        dto.precacheNext = false
        dto.maxBitrate = "128"
        try await repo.update(dto)
        let fetched = try await repo.fetch(id: dto.id)
        #expect(fetched?.name == "Renamed")
        #expect(fetched?.precacheNext == false)
        #expect(fetched?.maxBitrate == "128")
    }

    @Test("updateLastConnected writes only last_connected_at")
    func updateLastConnected() async throws {
        let db = try await makeDB()
        let repo = JellyfinServerRepository(database: db)
        let dto = self.sample()
        try await repo.insert(dto)
        try await repo.updateLastConnected(id: dto.id, at: Date(timeIntervalSince1970: 1_750_000_000))
        let fetched = try #require(try await repo.fetch(id: dto.id))
        #expect(fetched.lastConnectedAt?.timeIntervalSince1970 == 1_750_000_000)
        #expect(fetched.name == "Home")
        #expect(fetched.userID == dto.userID)
    }

    @Test("delete removes the row")
    func deleteRow() async throws {
        let db = try await makeDB()
        let repo = JellyfinServerRepository(database: db)
        let dto = self.sample()
        try await repo.insert(dto)
        try await repo.delete(id: dto.id)
        #expect(try await repo.fetch(id: dto.id) == nil)
    }

    @Test("metadata cache: upsert then fetch round-trip")
    func cacheRoundTrip() async throws {
        let db = try await makeDB()
        let repo = JellyfinServerRepository(database: db)
        let dto = self.sample()
        try await repo.insert(dto)
        let payload = Data("{\"Id\":\"3f9c0d2e8b7a4c1d9e5f6a7b8c9d0e1f\"}".utf8)
        try await repo.upsertCache(serverID: dto.id, entityKind: "album", entityID: "a1", payloadJSON: payload)
        let fetched = try await repo.fetchCache(serverID: dto.id, entityKind: "album", entityID: "a1")
        #expect(fetched == payload)
    }

    @Test("metadata cache: upsert replaces the existing payload")
    func cacheUpsert() async throws {
        let db = try await makeDB()
        let repo = JellyfinServerRepository(database: db)
        let dto = self.sample()
        try await repo.insert(dto)
        try await repo.upsertCache(serverID: dto.id, entityKind: "album", entityID: "a1", payloadJSON: Data("a".utf8))
        try await repo.upsertCache(serverID: dto.id, entityKind: "album", entityID: "a1", payloadJSON: Data("b".utf8))
        #expect(try await repo.fetchCache(serverID: dto.id, entityKind: "album", entityID: "a1") == Data("b".utf8))
        #expect(try await self.cacheRowCount(db) == 1)
    }

    @Test("metadata cache: fetch returns nil for a missing key")
    func cacheMiss() async throws {
        let db = try await makeDB()
        let repo = JellyfinServerRepository(database: db)
        let dto = self.sample()
        try await repo.insert(dto)
        #expect(try await repo.fetchCache(serverID: dto.id, entityKind: "album", entityID: "missing") == nil)
    }

    @Test("metadata cache: fetch ignores an entry older than 7 days")
    func cacheStaleIgnored() async throws {
        let db = try await makeDB()
        let repo = JellyfinServerRepository(database: db)
        let dto = self.sample()
        try await repo.insert(dto)
        try await self.insertCacheRow(db, serverID: dto.id, entityID: "old", fetchedAt: Date().addingTimeInterval(-8 * 86400))
        #expect(try await repo.fetchCache(serverID: dto.id, entityKind: "album", entityID: "old") == nil)
    }

    @Test("metadata cache: deleteCache clears only that server's rows")
    func cacheDelete() async throws {
        let db = try await makeDB()
        let repo = JellyfinServerRepository(database: db)
        let first = self.sample(name: "One")
        let second = self.sample(name: "Two")
        try await repo.insert(first)
        try await repo.insert(second)
        try await repo.upsertCache(serverID: first.id, entityKind: "album", entityID: "a1", payloadJSON: Data("x".utf8))
        try await repo.upsertCache(serverID: first.id, entityKind: "song", entityID: "s1", payloadJSON: Data("y".utf8))
        try await repo.upsertCache(serverID: second.id, entityKind: "album", entityID: "a1", payloadJSON: Data("z".utf8))
        try await repo.deleteCache(serverID: first.id)
        #expect(try await repo.fetchCache(serverID: first.id, entityKind: "album", entityID: "a1") == nil)
        #expect(try await repo.fetchCache(serverID: first.id, entityKind: "song", entityID: "s1") == nil)
        #expect(try await repo.fetchCache(serverID: second.id, entityKind: "album", entityID: "a1") == Data("z".utf8))
    }

    @Test("pruneStaleCache removes only rows older than 7 days")
    func pruneRemovesOnlyStale() async throws {
        let db = try await makeDB()
        let repo = JellyfinServerRepository(database: db)
        let dto = self.sample()
        try await repo.insert(dto)
        try await self.insertCacheRow(db, serverID: dto.id, entityID: "old", fetchedAt: Date().addingTimeInterval(-8 * 86400))
        try await self.insertCacheRow(db, serverID: dto.id, entityID: "fresh", fetchedAt: Date().addingTimeInterval(-1 * 86400))
        try await repo.pruneStaleCache()
        #expect(try await self.cacheRowCount(db) == 1)
        #expect(try await repo.fetchCache(serverID: dto.id, entityKind: "album", entityID: "fresh") != nil)
    }

    @Test("pruneStaleCache is a no-op when all entries are fresh")
    func pruneNoop() async throws {
        let db = try await makeDB()
        let repo = JellyfinServerRepository(database: db)
        let dto = self.sample()
        try await repo.insert(dto)
        try await repo.upsertCache(serverID: dto.id, entityKind: "album", entityID: "a1", payloadJSON: Data("x".utf8))
        try await repo.pruneStaleCache()
        #expect(try await repo.fetchCache(serverID: dto.id, entityKind: "album", entityID: "a1") != nil)
    }

    @Test("Jellyfin rows never touch the Subsonic tables")
    func subsonicTablesUntouched() async throws {
        let db = try await makeDB()
        let repo = JellyfinServerRepository(database: db)
        try await repo.insert(self.sample())
        let servers = try await db.read { grdb in
            try Int.fetchOne(grdb, sql: "SELECT COUNT(*) FROM subsonic_servers") ?? -1
        }
        let cache = try await db.read { grdb in
            try Int.fetchOne(grdb, sql: "SELECT COUNT(*) FROM subsonic_metadata_cache") ?? -1
        }
        #expect(servers == 0)
        #expect(cache == 0)
    }
}
