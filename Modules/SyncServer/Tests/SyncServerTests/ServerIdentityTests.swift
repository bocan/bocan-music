import Foundation
import Security
import Testing
@testable import SyncServer

/// In-memory identity store for tests: stable material, never touches the
/// Keychain. `secIdentity` is unsupported (the real `SecIdentity` path is
/// covered by `KeychainIdentityStoreTests` and the phase 22-3 loopback test).
final class InMemoryIdentityStore: IdentityStoring, Sendable {
    let material: SelfSignedCert.Material

    init() throws {
        self.material = try SelfSignedCert.generate()
    }

    func loadOrCreate() throws -> SelfSignedCert.Material {
        self.material
    }

    func secIdentity(for _: SelfSignedCert.Material) throws -> SecIdentity {
        throw SyncServerError.identity(reason: "inMemoryHasNoSecIdentity", status: nil)
    }
}

@Suite("ServerIdentity")
struct ServerIdentityTests {
    @Test("fingerprint is 64 lowercase hex characters")
    func fingerprintFormat() async throws {
        let identity = try ServerIdentity(store: InMemoryIdentityStore())
        let fingerprint = try await identity.fingerprint()
        #expect(fingerprint.hex.count == 64)
        #expect(fingerprint.hex.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    @Test("repeated calls on one instance return a stable fingerprint")
    func stableWithinInstance() async throws {
        let identity = try ServerIdentity(store: InMemoryIdentityStore())
        let first = try await identity.fingerprint()
        let second = try await identity.fingerprint()
        #expect(first == second)
    }

    @Test("two instances sharing a store see the same identity")
    func stableAcrossInstances() async throws {
        let store = try InMemoryIdentityStore()
        let first = ServerIdentity(store: store)
        let second = ServerIdentity(store: store)
        let firstFingerprint = try await first.fingerprint()
        let secondFingerprint = try await second.fingerprint()
        #expect(firstFingerprint == secondFingerprint)
    }

    @Test("common name is exposed")
    func commonNameExposed() async throws {
        let identity = try ServerIdentity(store: InMemoryIdentityStore())
        #expect(try await identity.commonName().hasPrefix("bocan-mac-"))
    }
}
