import Foundation
import Security
import Testing
@testable import SyncServer

/// Exercises the real login-Keychain path with a unique, cleaned-up service
/// string. This is the one suite in the module that touches the Keychain; the
/// rest use the in-memory fake.
@Suite("KeychainIdentityStore")
struct KeychainIdentityStoreTests {
    private func uniqueStore() -> KeychainIdentityStore {
        KeychainIdentityStore(service: "io.cloudcauldron.bocan.sync.test.\(UUID().uuidString)")
    }

    @Test("loadOrCreate persists a stable identity across calls")
    func stableIdentity() throws {
        let store = self.uniqueStore()
        defer { store.deleteAll() }

        let first = try store.loadOrCreate()
        let second = try store.loadOrCreate()

        #expect(first.certificateDER == second.certificateDER)
        #expect(first.privateKeyX963 == second.privateKeyX963)
        #expect(first.commonName.hasPrefix("bocan-mac-"))
    }

    @Test("secIdentity pairs the stored key with its certificate")
    func secIdentityPairsKeyAndCert() throws {
        let store = self.uniqueStore()
        defer { store.deleteAll() }

        let material = try store.loadOrCreate()
        let identity = try store.secIdentity(for: material)

        var certRef: SecCertificate?
        let status = SecIdentityCopyCertificate(identity, &certRef)
        #expect(status == errSecSuccess)

        let recoveredCert = try #require(certRef)
        let der = SecCertificateCopyData(recoveredCert) as Data
        #expect(der == material.certificateDER)
    }

    @Test("deleteAll removes the stored identity")
    func deleteAllClears() throws {
        let store = self.uniqueStore()
        let first = try store.loadOrCreate()
        store.deleteAll()
        let second = try store.loadOrCreate()
        // A fresh identity is generated after deletion, so the certificate differs.
        #expect(first.certificateDER != second.certificateDER)
        store.deleteAll()
    }
}
