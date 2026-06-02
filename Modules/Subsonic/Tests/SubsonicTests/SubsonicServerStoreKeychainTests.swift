import Foundation
import Persistence
import Security
import Testing
@testable import Subsonic

/// Probes whether the data-protection Keychain is writable in this process.
///
/// `SubsonicServerStore` now uses the data-protection Keychain
/// (`kSecUseDataProtectionKeychain: true`). Unsigned `swift test` binaries lack the
/// `keychain-access-groups` entitlement and get `errSecMissingEntitlement` (-34018),
/// so the whole suite is skipped there; the signed app build exercises the real path.
private func subsonicDataProtectionKeychainAvailable() -> Bool {
    let account = "probe-\(UUID().uuidString)"
    let base: [CFString: Any] = [
        kSecUseDataProtectionKeychain: true,
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: "io.cloudcauldron.bocan.subsonic.probe",
        kSecAttrAccount: account,
    ]
    var add = base
    add[kSecValueData] = Data("x".utf8)
    add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(add as CFDictionary, nil)
    guard status == errSecSuccess else { return false }
    _ = SecItemDelete(base as CFDictionary)
    return true
}

@Suite("SubsonicServerStore", .serialized, .enabled(if: subsonicDataProtectionKeychainAvailable()))
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

    @Test("Keychain item retains kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly after update (#285)")
    func updatePreservesAccessibility() async throws {
        let (store, _) = try await makeStore()
        let server = self.makeServer()
        try await store.add(server, secret: "initial")
        var updated = server
        updated.name = "Rotated"
        try await store.update(updated, newSecret: "rotated")

        // Query with the expected accessibility class: if the update path set the
        // attribute correctly, the item is findable under this class. If the update
        // silently inherited a different class, the query would return errSecItemNotFound.
        let accessibilityQuery: [CFString: Any] = [
            kSecUseDataProtectionKeychain: true,
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "io.cloudcauldron.bocan.subsonic",
            kSecAttrAccount: server.keychainAccount,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var accessibilityResult: AnyObject?
        let accessibilityStatus = SecItemCopyMatching(accessibilityQuery as CFDictionary, &accessibilityResult)
        #expect(
            accessibilityStatus == errSecSuccess,
            "Keychain item not found with kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly after update; status=\(accessibilityStatus)"
        )
        try? await store.remove(id: server.id)
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

    @Test("a credential left in the legacy Keychain is migrated to the data-protection Keychain on read")
    func legacyKeychainMigration() async throws {
        let (store, _) = try await makeStore()
        let id = UUID()
        let account = id.uuidString
        let service = "io.cloudcauldron.bocan.subsonic"

        // Write a credential directly into the LEGACY Keychain (no kSecUseDataProtectionKeychain),
        // mimicking an install from before the data-protection switch.
        let data = try JSONEncoder().encode(SubsonicCredential(kind: "tokenSalt", secret: "legacy-secret"))
        let legacyBase: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        _ = SecItemDelete(legacyBase as CFDictionary)
        var legacyAdd = legacyBase
        legacyAdd[kSecValueData] = data
        #expect(SecItemAdd(legacyAdd as CFDictionary, nil) == errSecSuccess)

        // Reading through the store should find it via the legacy fallback and migrate it.
        let secret = try await store.secret(for: id)
        #expect(secret == "legacy-secret")

        // The legacy item should now be gone.
        var legacyResult: AnyObject?
        var legacyRead = legacyBase
        legacyRead[kSecReturnData] = true
        legacyRead[kSecMatchLimit] = kSecMatchLimitOne
        #expect(SecItemCopyMatching(legacyRead as CFDictionary, &legacyResult) == errSecItemNotFound)

        // ...and the value now resolves from the data-protection Keychain.
        #expect(try await store.secret(for: id) == "legacy-secret")

        // Cleanup: no DB row exists, so delete the data-protection item directly.
        let dpDelete: [CFString: Any] = [
            kSecUseDataProtectionKeychain: true,
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        _ = SecItemDelete(dpDelete as CFDictionary)
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
