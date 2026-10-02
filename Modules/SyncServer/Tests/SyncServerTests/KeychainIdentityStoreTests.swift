import Foundation
import os
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

    @Test("a certificate read that misses once returns the same identity")
    func oneMissedReadKeepsIdentity() throws {
        let service = "io.cloudcauldron.bocan.sync.test.\(UUID().uuidString)"
        let store = KeychainIdentityStore(service: service)
        defer { store.deleteAll() }
        let first = try store.loadOrCreate()

        let missesLeft = OSAllocatedUnfairLock(initialState: 1)
        let flaky = KeychainIdentityStore(service: service) {
            missesLeft.withLock { left in
                guard left > 0 else { return false }
                left -= 1
                return true
            }
        }
        let second = try flaky.loadOrCreate()

        #expect(missesLeft.withLock { $0 } == 0)
        #expect(first.certificateDER == second.certificateDER)
        #expect(first.privateKeyX963 == second.privateKeyX963)
    }

    @Test("a certificate that stays missing is made again for the same key")
    func stableMissMakesNewCertificate() throws {
        let service = "io.cloudcauldron.bocan.sync.test.\(UUID().uuidString)"
        let store = KeychainIdentityStore(service: service)
        defer { store.deleteAll() }
        let first = try store.loadOrCreate()

        let second = try KeychainIdentityStore(service: service) { true }.loadOrCreate()

        #expect(first.certificateDER != second.certificateDER)
        #expect(first.privateKeyX963 == second.privateKeyX963)
    }

    @Test("deleteAll removes every certificate item of the store")
    func deleteAllRemovesCertificateItems() throws {
        let service = "io.cloudcauldron.bocan.sync.test.\(UUID().uuidString)"
        let store = KeychainIdentityStore(service: service)
        let first = try store.loadOrCreate()
        // A second certificate for the same key, whose blob replaces the first.
        let second = try KeychainIdentityStore(service: service) { true }.loadOrCreate()
        #expect(first.commonName != second.commonName)
        // A read directly after the write can miss (#617), so wait for both items.
        #expect(Self.certificateAppears(label: first.commonName))
        #expect(Self.certificateAppears(label: second.commonName))

        store.deleteAll()

        #expect(Self.certificateStatus(label: first.commonName) == errSecItemNotFound)
        #expect(Self.certificateStatus(label: second.commonName) == errSecItemNotFound)
    }

    private static func certificateAppears(label: String) -> Bool {
        for _ in 0 ..< 50 {
            if self.certificateStatus(label: label) == errSecSuccess {
                return true
            }
            usleep(20000)
        }
        return false
    }

    private static func certificateStatus(label: String) -> OSStatus {
        var item: CFTypeRef?
        return SecItemCopyMatching([
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
        ] as CFDictionary, &item)
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
