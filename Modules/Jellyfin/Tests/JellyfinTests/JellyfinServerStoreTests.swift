import Foundation
import Persistence
import Security
import Testing
@testable import Jellyfin

/// Probes whether the login Keychain is writable in this process.
///
/// `JellyfinServerStore` keeps the token in the login (file-based) Keychain.
/// Some `swift test` environments (headless CI) cannot reach it at all, so the
/// suite is skipped there; the signed app build exercises the real path.
func jellyfinKeychainAvailable() -> Bool {
    let base: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: "io.cloudcauldron.bocan.jellyfin.probe",
        kSecAttrAccount: "probe-\(UUID().uuidString)",
    ]
    var add = base
    add[kSecValueData] = Data("x".utf8)
    guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { return false }
    _ = SecItemDelete(base as CFDictionary)
    return true
}

@Suite("JellyfinServerStore", .serialized, .enabled(if: jellyfinKeychainAvailable()))
struct JellyfinServerStoreTests {
    /// A store with its own Keychain service name, so no test touches a real server's item.
    private struct Harness {
        let store: JellyfinServerStore
        let repository: JellyfinServerRepository
        let database: Persistence.Database
        let service: String
    }

    private func makeHarness() async throws -> Harness {
        let database = try await Persistence.Database(location: .inMemory)
        let repository = JellyfinServerRepository(database: database)
        let service = "io.cloudcauldron.bocan.jellyfin.test.\(UUID().uuidString)"
        return Harness(
            store: JellyfinServerStore(repository: repository, keychainService: service),
            repository: repository,
            database: database,
            service: service
        )
    }

    private func makeServer(name: String = "Home") -> JellyfinServer {
        JellyfinServer(
            name: "\(name)-\(UUID().uuidString.prefix(8))",
            serverURL: URL(string: "https://jf.example.test") ?? URL(filePath: "/"),
            userID: "7f3b1c0e9d2a4e5f8a6b0c1d2e3f4a5b",
            username: "listener"
        )
    }

    private func session(token: String = "TOKEN-ONE-0123456789") -> JellyfinSession {
        JellyfinSession(userID: "7f3b1c0e9d2a4e5f8a6b0c1d2e3f4a5b", username: "listener", accessToken: token)
    }

    /// The raw Keychain blob for an account, read without going through the store.
    private func rawKeychainBlob(service: String, account: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private func cleanUp(_ harness: Harness) async {
        guard let all = try? await harness.store.fetchAll() else { return }
        for server in all {
            try? await harness.store.remove(id: server.id)
        }
    }

    @Test("add stores the server and the token; both read back")
    func addAndRead() async throws {
        let harness = try await self.makeHarness()
        let server = self.makeServer()
        try await harness.store.add(server, session: self.session())
        let fetched = try #require(try await harness.store.fetch(id: server.id))
        #expect(fetched.id == server.id)
        #expect(fetched.userID == server.userID)
        #expect(fetched.deviceID == server.deviceID)
        #expect(try await harness.store.accessToken(for: server.id) == "TOKEN-ONE-0123456789")
        await self.cleanUp(harness)
    }

    @Test("the Keychain blob is v1, kind accessToken, with the token as the secret")
    func blobShape() async throws {
        let harness = try await self.makeHarness()
        let server = self.makeServer()
        try await harness.store.add(server, session: self.session())
        let blob = try #require(self.rawKeychainBlob(service: harness.service, account: server.id.uuidString))
        let object = try #require(try JSONSerialization.jsonObject(with: blob) as? [String: Any])
        #expect(object["v"] as? Int == 1)
        #expect(object["kind"] as? String == "accessToken")
        #expect(object["secret"] as? String == "TOKEN-ONE-0123456789")
        await self.cleanUp(harness)
    }

    @Test("the token is never written to the database")
    func tokenNotInDatabase() async throws {
        let harness = try await self.makeHarness()
        let server = self.makeServer()
        try await harness.store.add(server, session: self.session(token: "UNIQUE-TOKEN-NEEDLE"))
        let dump = try await harness.database.read { grdb in
            try String.fetchAll(
                grdb,
                sql: "SELECT group_concat(id || name || server_url || user_id || ifnull(username, '') || device_id) FROM jellyfin_servers"
            )
        }
        #expect(!dump.joined().contains("UNIQUE-TOKEN-NEEDLE"))
        await self.cleanUp(harness)
    }

    @Test("a failed database write removes the Keychain item again")
    func addRollsBackTheKeychain() async throws {
        let harness = try await self.makeHarness()
        let first = self.makeServer()
        try await harness.store.add(first, session: self.session())
        var clash = self.makeServer()
        clash.name = first.name
        await #expect(throws: (any Error).self) {
            try await harness.store.add(clash, session: self.session(token: "CLASH-TOKEN"))
        }
        #expect(self.rawKeychainBlob(service: harness.service, account: clash.id.uuidString) == nil)
        #expect(self.rawKeychainBlob(service: harness.service, account: first.id.uuidString) != nil)
        await self.cleanUp(harness)
    }

    @Test("signing in again replaces the token and keeps the row")
    func updateWithNewSession() async throws {
        let harness = try await self.makeHarness()
        var server = self.makeServer()
        try await harness.store.add(server, session: self.session())
        server.name += "-renamed"
        try await harness.store.update(server, newSession: self.session(token: "TOKEN-TWO"))
        #expect(try await harness.store.accessToken(for: server.id) == "TOKEN-TWO")
        #expect(try await harness.store.fetch(id: server.id)?.name == server.name)
        await self.cleanUp(harness)
    }

    @Test("an update with no new session leaves the token alone")
    func updateKeepsToken() async throws {
        let harness = try await self.makeHarness()
        var server = self.makeServer()
        try await harness.store.add(server, session: self.session())
        server.precacheNext = false
        try await harness.store.update(server)
        #expect(try await harness.store.accessToken(for: server.id) == "TOKEN-ONE-0123456789")
        #expect(try await harness.store.fetch(id: server.id)?.precacheNext == false)
        await self.cleanUp(harness)
    }

    @Test("remove deletes the row, the Keychain item and the cached metadata")
    func removeEverything() async throws {
        let harness = try await self.makeHarness()
        let server = self.makeServer()
        try await harness.store.add(server, session: self.session())
        try await harness.repository.upsertCache(serverID: server.id, entityKind: "album", entityID: "a1", payloadJSON: Data("x".utf8))
        try await harness.store.remove(id: server.id)
        #expect(try await harness.store.fetch(id: server.id) == nil)
        #expect(self.rawKeychainBlob(service: harness.service, account: server.id.uuidString) == nil)
        #expect(try await harness.repository.fetchCache(serverID: server.id, entityKind: "album", entityID: "a1") == nil)
    }

    @Test("a missing item reports a credential-missing error after reading again")
    func missingToken() async throws {
        let harness = try await self.makeHarness()
        let error = await #expect(throws: JellyfinError.self) {
            _ = try await harness.store.accessToken(for: UUID())
        }
        #expect(error?.isCredentialMissing == true)
    }

    @Test("the orphan sweep removes items with no row and keeps the others")
    func orphanSweep() async throws {
        let harness = try await self.makeHarness()
        let kept = self.makeServer(name: "Kept")
        let orphan = self.makeServer(name: "Orphan")
        try await harness.store.add(kept, session: self.session())
        try await harness.store.add(orphan, session: self.session(token: "ORPHAN-TOKEN"))
        // Remove the row behind the store's back, as a crash between the two steps would.
        try await harness.repository.delete(id: orphan.id)
        try await harness.store.migrateOrphans()
        #expect(self.rawKeychainBlob(service: harness.service, account: orphan.id.uuidString) == nil)
        #expect(self.rawKeychainBlob(service: harness.service, account: kept.id.uuidString) != nil)
        await self.cleanUp(harness)
    }

    @Test("fetchAll returns servers in sort order")
    func fetchAllOrder() async throws {
        let harness = try await self.makeHarness()
        var later = self.makeServer(name: "Later")
        later.sortIndex = 5
        var earlier = self.makeServer(name: "Earlier")
        earlier.sortIndex = 1
        try await harness.store.add(later, session: self.session())
        try await harness.store.add(earlier, session: self.session())
        #expect(try await harness.store.fetchAll().map(\.id) == [earlier.id, later.id])
        await self.cleanUp(harness)
    }

    @Test("every setting survives the trip through the database")
    func conversionRoundTrip() async throws {
        let harness = try await self.makeHarness()
        let server = JellyfinServer(
            name: "Round trip \(UUID().uuidString.prefix(6))",
            serverURL: URL(string: "https://jf.example.test:8920/prefix/") ?? URL(filePath: "/"),
            userID: "user-guid",
            username: "chris",
            deviceID: "DEVICE-XYZ",
            allowSelfSignedTLS: true,
            maxBitrate: .kbps(192),
            preferredFormat: .opus,
            precacheNext: false,
            includeInGlobalSearch: false,
            showInSidebar: false,
            scrobble: false,
            syncStars: false,
            sortIndex: 9,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastConnectedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
        try await harness.store.add(server, session: self.session())
        let fetched = try #require(try await harness.store.fetch(id: server.id))
        #expect(fetched == server)
        #expect(fetched.serverURL.absoluteString == "https://jf.example.test:8920/prefix")
        await self.cleanUp(harness)
    }

    @Test("an unknown stored format reads as original instead of hiding the server")
    func unknownFormat() async throws {
        let harness = try await self.makeHarness()
        let server = self.makeServer()
        try await harness.store.add(server, session: self.session())
        var dto = try #require(try await harness.repository.fetch(id: server.id))
        dto.preferredFormat = "wavpack"
        try await harness.repository.update(dto)
        #expect(try await harness.store.fetch(id: server.id)?.preferredFormat == .original)
        await self.cleanUp(harness)
    }

    @Test("updateLastConnected writes the timestamp")
    func lastConnected() async throws {
        let harness = try await self.makeHarness()
        let server = self.makeServer()
        try await harness.store.add(server, session: self.session())
        try await harness.store.updateLastConnected(serverID: server.id, at: Date(timeIntervalSince1970: 1_760_000_000))
        #expect(try await harness.store.fetch(id: server.id)?.lastConnectedAt?.timeIntervalSince1970 == 1_760_000_000)
        await self.cleanUp(harness)
    }
}
