import Foundation
import Security

/// A `Sendable` box around `SecIdentity`.
///
/// `SecIdentity` is an immutable, thread-safe CoreFoundation Security type that
/// predates Swift's `Sendable` annotations, so passing it across concurrency
/// domains (from the `ServerIdentity` actor to the `NWListener` setup) is safe.
/// This is the clearly-marked Security boundary the concurrency standards allow.
public struct SendableSecIdentity: @unchecked Sendable {
    public let value: SecIdentity

    public init(_ value: SecIdentity) {
        self.value = value
    }
}

/// The Phone Sync server's stable TLS identity: a P-256 key and self-signed
/// certificate created once and stored in the login Keychain (see
/// sync-protocol.md section 2). Exposes a `SecIdentity` for the `NWListener` and
/// the SHA-256 fingerprint for the Bonjour TXT record and the pairing math.
///
/// This is a separate identity from any future Phase 18 remote-control server.
public actor ServerIdentity {
    /// The loaded identity, ready for the TLS listener.
    public struct Loaded: Sendable {
        public let secIdentity: SendableSecIdentity
        public let certificateDER: Data
        public let fingerprint: ServerFingerprint
        public let commonName: String
    }

    private let store: any IdentityStoring
    private var cachedMaterial: SelfSignedCert.Material?

    /// Production initializer: backs the identity with the login Keychain.
    public init() {
        self.store = KeychainIdentityStore()
    }

    /// Test initializer: injects a store (for example an in-memory fake).
    init(store: any IdentityStoring) {
        self.store = store
    }

    /// The certificate fingerprint (lowercase-hex SHA-256 of the DER). Loads or
    /// creates the identity on first call.
    public func fingerprint() throws -> ServerFingerprint {
        try ServerFingerprint(certificateDER: self.material().certificateDER)
    }

    /// The certificate DER.
    public func certificateDER() throws -> Data {
        try self.material().certificateDER
    }

    /// The certificate common name (`bocan-mac-<8 hex>`).
    public func commonName() throws -> String {
        try self.material().commonName
    }

    /// The full loaded identity, including the `SecIdentity` for the listener.
    public func load() throws -> Loaded {
        let material = try self.material()
        return try Loaded(
            secIdentity: SendableSecIdentity(self.store.secIdentity(for: material)),
            certificateDER: material.certificateDER,
            fingerprint: ServerFingerprint(certificateDER: material.certificateDER),
            commonName: material.commonName
        )
    }

    private func material() throws -> SelfSignedCert.Material {
        if let cachedMaterial { return cachedMaterial }
        let material = try self.store.loadOrCreate()
        self.cachedMaterial = material
        return material
    }
}
