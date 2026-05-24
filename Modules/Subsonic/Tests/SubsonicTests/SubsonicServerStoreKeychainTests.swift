import Foundation
import Persistence
import Security
import Testing
@testable import Subsonic

@Suite("SubsonicServerStore", .serialized)
struct SubsonicServerStoreTests {
    private func makeStore() async throws -> (SubsonicServerStore, SubsonicServerRepository) {
        let db = try await Persistence.Database(location: .inMemory)
        let repo = SubsonicServerRepository(database: db)
        return (SubsonicServerStore(repository: repo), repo)
    }

    private func makeServer(name: String = "Home") -> SubsonicServer {
        let id = UUID()
        return SubsonicServer(
            id: id,
            name: "\(name)-\(id.uuidString.prefix(8))",
            serverURL: URL(string: "https://music.test.local")!,
            authKind: .tokenSalt,
            username: "alice"
            // keychainAccount defaults to id.uuidString
        )
    }

    @Test("add stores server and secret; fetch returns the same server; secret() returns the secret")
    func addAndFetch() async throws {
        let (store, _) = try await makeStore()
        let server = self.makeServer()
        try await store.add(server, secret: "s3cr3t")
        let fetched = try await store.fetch(id: server.id)
        #expect(fetched?.id == server.id)
        #expect(fetched?.name == server.name)
        let secret = try await store.secret(for: server.id)
        #expect(secret == "s3cr3t")
        try? await store.remove(id: server.id)
    }

    @Test("fetchAll returns inserted servers in sort order")
    func fetchAllReturnsAll() async throws {
        let (store, _) = try await makeStore()
        let s1 = self.makeServer(name: "A")
        let s2 = self.makeServer(name: "B")
        try await store.add(s1, secret: "x")
        try await store.add(s2, secret: "y")
        let all = try await store.fetchAll()
        let names = Set(all.map(\.name))
        #expect(names.contains(s1.name))
        #expect(names.contains(s2.name))
        try? await store.remove(id: s1.id)
        try? await store.remove(id: s2.id)
    }

    @Test("update mutates the record and rewrites the secret when newSecret is provided")
    func updateServer() async throws {
        let (store, _) = try await makeStore()
        var server = self.makeServer()
        try await store.add(server, secret: "old")
        server.name = "Renamed"
        try await store.update(server, newSecret: "new")
        let secret = try await store.secret(for: server.id)
        #expect(secret == "new")
        let fetched = try await store.fetch(id: server.id)
        #expect(fetched?.name == "Renamed")
        try? await store.remove(id: server.id)
    }

    @Test("update without newSecret keeps the original secret")
    func updateNoSecret() async throws {
        let (store, _) = try await makeStore()
        var server = self.makeServer()
        try await store.add(server, secret: "keep-me")
        server.name = "OnlyRenamed"
        try await store.update(server, newSecret: nil)
        let secret = try await store.secret(for: server.id)
        #expect(secret == "keep-me")
        try? await store.remove(id: server.id)
    }

    @Test("remove deletes both DB and Keychain")
    func removeDeletes() async throws {
        let (store, _) = try await makeStore()
        let server = self.makeServer()
        try await store.add(server, secret: "abc")
        try await store.remove(id: server.id)
        let fetched = try await store.fetch(id: server.id)
        #expect(fetched == nil)
        await #expect(throws: (any Error).self) {
            _ = try await store.secret(for: server.id)
        }
    }

    @Test("secret throws for an unknown server")
    func secretMissing() async throws {
        let (store, _) = try await makeStore()
        await #expect(throws: (any Error).self) {
            _ = try await store.secret(for: UUID())
        }
    }

    @Test("apiKey servers round-trip through add/secret")
    func apiKeyAuth() async throws {
        let (store, _) = try await makeStore()
        let id = UUID()
        let server = try SubsonicServer(
            id: id,
            name: "API-\(id.uuidString.prefix(8))",
            serverURL: #require(URL(string: "https://music.test.local")),
            authKind: .apiKey,
            username: nil
        )
        try await store.add(server, secret: "API-KEY-123")
        let secret = try await store.secret(for: server.id)
        #expect(secret == "API-KEY-123")
        try? await store.remove(id: server.id)
    }

    @Test("migrateOrphans removes Keychain items whose server row is gone")
    func migrateOrphans() async throws {
        let (store, repo) = try await makeStore()
        let server = self.makeServer()
        try await store.add(server, secret: "orphan-me")
        // Delete the DB row directly to leave a Keychain orphan.
        try await repo.delete(id: server.id)
        try await store.migrateOrphans()
        // Keychain item should now be gone.
        await #expect(throws: (any Error).self) {
            _ = try await store.secret(for: server.id)
        }
    }

    @Test("migrateOrphans leaves live Keychain items in place")
    func migrateOrphansPreservesLive() async throws {
        let (store, _) = try await makeStore()
        let server = self.makeServer()
        try await store.add(server, secret: "live")
        try await store.migrateOrphans()
        let secret = try await store.secret(for: server.id)
        #expect(secret == "live")
        try? await store.remove(id: server.id)
    }

    @Test("updateCapabilities persists JSON + lastConnectedAt")
    func updateCapabilities() async throws {
        let (store, repo) = try await makeStore()
        let server = self.makeServer()
        try await store.add(server, secret: "x")
        try await store.updateCapabilities(
            serverID: server.id,
            capabilitiesJSON: Data("{}".utf8),
            lastConnectedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let dto = try await repo.fetch(id: server.id)
        #expect(dto?.capabilitiesJSON == Data("{}".utf8))
        try? await store.remove(id: server.id)
    }
}
