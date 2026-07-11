import Crypto
import Foundation
import Observability
import Security

/// Persists the Phone Sync server's P-256 identity and vends a `SecIdentity` for
/// the TLS listener. Behind a protocol so tests use an in-memory fake and never
/// touch the real Keychain.
protocol IdentityStoring: Sendable {
    /// Returns the existing identity material, generating and persisting a new
    /// one on first use. Stable across calls and process launches.
    func loadOrCreate() throws -> SelfSignedCert.Material
    /// Builds a `SecIdentity` (key + certificate) for the TLS listener.
    func secIdentity(for material: SelfSignedCert.Material) throws -> SecIdentity
}

/// Login-Keychain-backed identity store.
///
/// Uses the file-based login Keychain, not the data-protection Keychain
/// (matching `SubsonicServerStore`, which found the data-protection Keychain did
/// not survive local rebuilds). The private key is generated directly in the
/// Keychain so it is stored reliably. The certificate is stored two ways: its DER
/// as a generic-password blob (reliably queryable, unlike a certificate's
/// `kSecAttrLabel`) for the load path, and as a `SecCertificate` item so
/// `SecIdentityCreateWithCertificate` can pair it with the key.
struct KeychainIdentityStore: IdentityStoring {
    let service: String
    private let log = AppLogger.make(.sync)

    init(service: String = "io.cloudcauldron.bocan.sync") {
        self.service = service
    }

    private var keyTag: Data {
        Data("\(self.service).key".utf8)
    }

    private var certLabel: String {
        "\(self.service).cert"
    }

    private static let certAccount = "cert"

    // MARK: - IdentityStoring

    func loadOrCreate() throws -> SelfSignedCert.Material {
        let existingKey = try self.loadKey()
        let existingCertDER = try self.loadCertificateDER()

        // Both present: return the stable stored identity.
        if let existingKey, let existingCertDER {
            return try SelfSignedCert.Material(
                privateKeyX963: self.exportX963(existingKey),
                certificateDER: existingCertDER,
                commonName: self.commonName(ofDER: existingCertDER)
            )
        }

        // A certificate without its key is unusable (it was signed by a key we no
        // longer have); discard it and start fresh.
        let key: SecKey
        if let existingKey {
            key = existingKey
        } else {
            self.deleteCertificate()
            key = try self.generatePermanentKey()
        }

        let x963 = try self.exportX963(key)
        let cryptoKey = try P256.Signing.PrivateKey(x963Representation: x963)
        let made = try SelfSignedCert.makeCertificate(for: cryptoKey)
        try self.storeCertificate(made.der)
        self.log.debug("identity.created", ["cn": made.commonName])
        return SelfSignedCert.Material(
            privateKeyX963: x963,
            certificateDER: made.der,
            commonName: made.commonName
        )
    }

    func secIdentity(for material: SelfSignedCert.Material) throws -> SecIdentity {
        guard let cert = SecCertificateCreateWithData(nil, material.certificateDER as CFData) else {
            throw SyncServerError.identity(reason: "certParse", status: nil)
        }
        var identity: SecIdentity?
        let status = SecIdentityCreateWithCertificate(nil, cert, &identity)
        guard status == errSecSuccess, let identity else {
            throw SyncServerError.identity(reason: "secIdentity", status: status)
        }
        return identity
    }

    // MARK: - Test support

    /// Removes the key and certificate. Used by tests to clean up a unique
    /// service string; never called in production.
    func deleteAll() {
        SecItemDelete([
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: self.keyTag,
        ] as CFDictionary)
        self.deleteCertificate()
    }

    // MARK: - Key helpers

    private func generatePermanentKey() throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: self.keyTag,
            ],
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw SyncServerError.identity(reason: "keygen", status: nil)
        }
        return key
    }

    private func exportX963(_ key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            throw SyncServerError.identity(reason: "keyExport", status: nil)
        }
        return data
    }

    private func loadKey() throws -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: self.keyTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let item else {
            throw SyncServerError.identity(reason: "loadKey", status: status)
        }
        // SecItemCopyMatching with kSecReturnRef and kSecClassKey returns a SecKey.
        return (item as! SecKey) // swiftlint:disable:this force_cast
    }

    // MARK: - Certificate helpers

    private func loadCertificateDER() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: Self.certAccount,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw SyncServerError.identity(reason: "loadCert", status: status)
        }
        return data
    }

    private func storeCertificate(_ der: Data) throws {
        // Primary storage: the DER as a generic-password blob (reliably queryable).
        try self.writeCertificateBlob(der)

        // Secondary: a SecCertificate item so SecIdentityCreateWithCertificate can
        // pair the certificate with its key. Duplicate adds are fine.
        guard let cert = SecCertificateCreateWithData(nil, der as CFData) else {
            throw SyncServerError.identity(reason: "certParse", status: nil)
        }
        let status = SecItemAdd([
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: cert,
            kSecAttrLabel as String: self.certLabel,
        ] as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw SyncServerError.identity(reason: "certStore", status: status)
        }
    }

    private func writeCertificateBlob(_ der: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: Self.certAccount,
        ]
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: der] as CFDictionary)
        if update == errSecSuccess { return }
        if update == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = der
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw SyncServerError.identity(reason: "certBlobAdd", status: addStatus)
            }
            return
        }
        throw SyncServerError.identity(reason: "certBlobUpdate", status: update)
    }

    private func deleteCertificate() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: Self.certAccount,
        ] as CFDictionary)
        SecItemDelete([
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: self.certLabel,
        ] as CFDictionary)
    }

    private func commonName(ofDER der: Data) -> String {
        guard let cert = SecCertificateCreateWithData(nil, der as CFData) else {
            return "bocan-mac-unknown"
        }
        return (SecCertificateCopySubjectSummary(cert) as String?) ?? "bocan-mac-unknown"
    }
}
