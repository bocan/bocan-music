import Foundation
import Persistence
import Testing
@testable import Subsonic

/// Tests for the parts of `SubsonicServerStore` that do not touch the Keychain.
/// The keychainWrite/Read paths require entitlements not available to `swift test`,
/// so we cover the rest by seeding rows directly via the repository and exercising
/// the store's read APIs and orphan cleanup.
@Suite("SubsonicServerStore (read-only)", .serialized)
struct SubsonicServerStoreReadOnlyTests {
    private func makeStore() async throws -> (SubsonicServerStore, SubsonicServerRepository) {
        let db = try await Persistence.Database(location: .inMemory)
        let repo = SubsonicServerRepository(database: db)
        return (SubsonicServerStore(repository: repo), repo)
    }

    private func makeDTO(name: String = "Home") -> SubsonicServerDTO {
        let id = UUID()
        return SubsonicServerDTO(
            id: id,
            name: "\(name)-\(id.uuidString.prefix(8))",
            serverURL: URL(string: "https://music.test.local")!,
            authKind: "tokenSalt",
            username: "alice",
            keychainAccount: id.uuidString
        )
    }

    @Test("fetch returns nil for unknown id")
    func fetchMissing() async throws {
        let (store, _) = try await makeStore()
        #expect(try await store.fetch(id: UUID()) == nil)
    }

    @Test("fetch returns a server when its DTO is seeded via the repository")
    func fetchSeeded() async throws {
        let (store, repo) = try await makeStore()
        let dto = self.makeDTO()
        try await repo.insert(dto)
        let fetched = try await store.fetch(id: dto.id)
        #expect(fetched?.id == dto.id)
        #expect(fetched?.name == dto.name)
    }

    @Test("fetchAll returns all seeded servers")
    func fetchAllSeeded() async throws {
        let (store, repo) = try await makeStore()
        let a = self.makeDTO(name: "A")
        let b = self.makeDTO(name: "B")
        try await repo.insert(a)
        try await repo.insert(b)
        let all = try await store.fetchAll()
        let names = Set(all.map(\.name))
        #expect(names.contains(a.name))
        #expect(names.contains(b.name))
    }

    @Test("fetchAll skips rows with invalid authKind")
    func fetchAllSkipsInvalid() async throws {
        let (store, repo) = try await makeStore()
        var dto = self.makeDTO()
        dto.authKind = "bogus" // not a SubsonicAuthKind value
        try await repo.insert(dto)
        let all = try await store.fetchAll()
        #expect(all.contains { $0.id == dto.id } == false)
    }

    @Test("updateCapabilities persists capabilities + lastConnectedAt")
    func updateCaps() async throws {
        let (store, repo) = try await makeStore()
        let dto = self.makeDTO()
        try await repo.insert(dto)
        let payload = Data("{\"v\":\"1.16\"}".utf8)
        try await store.updateCapabilities(
            serverID: dto.id,
            capabilitiesJSON: payload,
            lastConnectedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
        let fetched = try await store.fetch(id: dto.id)
        #expect(fetched?.cachedCapabilitiesJSON == payload)
        #expect(fetched?.lastConnectedAt?.timeIntervalSince1970 == 1_750_000_000)
    }

    @Test("migrateOrphans runs without throwing on an empty store")
    func orphansEmpty() async throws {
        let (store, _) = try await makeStore()
        try await store.migrateOrphans()
    }

    @Test("migrateOrphans tolerates a populated store")
    func orphansPopulated() async throws {
        let (store, repo) = try await makeStore()
        try await repo.insert(self.makeDTO())
        try await store.migrateOrphans()
    }
}
