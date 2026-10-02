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
/// as a generic-password blob (reliably queryable by service) for the load path,
/// and as a `SecCertificate` item so `SecIdentityCreateWithCertificate` can pair
/// it with the key. The Keychain labels that item with the certificate's common
/// name and ignores any label given on add.
struct KeychainIdentityStore: IdentityStoring {
    let service: String
    /// Test seam: answers true to make one certificate read report "not found",
    /// the way the login Keychain does for an item written a moment before.
    private let simulateCertificateMiss: @Sendable () -> Bool
    private let log = AppLogger.make(.sync)

    init(
        service: String = "io.cloudcauldron.bocan.sync",
        simulateCertificateMiss: @escaping @Sendable () -> Bool = { false }
    ) {
        self.service = service
        self.simulateCertificateMiss = simulateCertificateMiss
    }

    private var keyTag: Data {
        Data("\(self.service).key".utf8)
    }

    private static let certAccount = "cert"

    /// Every certificate this module makes has a common name with this prefix
    /// (`SelfSignedCert.makeCertificate`). Cleanup never touches another name.
    private static let commonNamePrefix = "bocan-mac-"

    // MARK: - IdentityStoring

    func loadOrCreate() throws -> SelfSignedCert.Material {
        var existingKey = try self.loadKey()
        var existingCertDER = try self.loadCertificateDER()

        // One half without the other is the state a late Keychain read leaves:
        // the login Keychain can answer "not found" for an item written a moment
        // before while other writes are in progress (#617). Read the missing half
        // again before replacing an identity that paired phones trust (#622).
        if existingKey != nil, existingCertDER == nil {
            existingCertDER = try self.readAgain("cert") { try self.loadCertificateDER() }
        } else if existingKey == nil, existingCertDER != nil {
            existingKey = try self.readAgain("key") { try self.loadKey() }
        }

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

    // MARK: - Settled reads

    /// How many times a missing half of the identity is read again. With the
    /// growing wait below, the last read is 300 ms after the first miss; the
    /// misses measured for #617 ended within 100 ms.
    private static let rereadAttempts = 5

    /// Reads one half of the identity again, with a growing wait, and returns
    /// nil only when every read answers "not found".
    private func readAgain<Item>(_ half: String, _ read: () throws -> Item?) rethrows -> Item? {
        for attempt in 1 ... Self.rereadAttempts {
            usleep(useconds_t(20000 * attempt))
            if let item = try read() {
                self.log.debug("identity.read.settled", ["half": half, "attempt": attempt])
                return item
            }
        }
        self.log.warning("identity.read.missing", ["half": half, "attempts": Self.rereadAttempts])
        return nil
    }

    // MARK: - Test support

    /// Removes the key and certificate. Used by tests to clean up a unique
    /// service string; never called in production.
    func deleteAll() {
        // Certificates first: they are found through the key.
        self.deleteCertificate()
        SecItemDelete([
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: self.keyTag,
        ] as CFDictionary)
    }

    // MARK: - Key helpers

    /// Serialises permanent-key generation: concurrent `SecKeyCreateRandomKey`
    /// writes into the login Keychain transiently fail when parallel test
    /// suites each create an identity at the same time.
    private static let keygenLock = NSLock()

    private func generatePermanentKey() throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: self.keyTag,
            ],
        ]
        Self.keygenLock.lock()
        defer { Self.keygenLock.unlock() }
        // Writing a permanent key to the login Keychain can still transiently
        // fail under contention from outside the process; retry with a growing
        // backoff before giving up.
        var lastError: CFError?
        let attempts = 5
        for attempt in 1 ... attempts {
            var error: Unmanaged<CFError>?
            if let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) {
                return key
            }
            lastError = error?.takeRetainedValue()
            if attempt < attempts {
                usleep(useconds_t(20000 * attempt))
            }
        }
        self.log.error("identity.keygen.failed", ["error": String(describing: lastError)])
        throw SyncServerError.identity(reason: "keygen", status: nil)
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
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let item else {
            throw SyncServerError.identity(reason: "loadKey", status: status)
        }
        // SecItemCopyMatching with kSecReturnRef and kSecClassKey returns a SecKey.
        return (item as! SecKey) // swiftlint:disable:this force_cast
    }

    // MARK: - Certificate helpers

    private func loadCertificateDER() throws -> Data? {
        if self.simulateCertificateMiss() {
            return nil
        }
        return try self.readCertificateBlob()
    }

    private func readCertificateBlob() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: Self.certAccount,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
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
        ] as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw SyncServerError.identity(reason: "certStore", status: status)
        }
        self.waitUntilReadable(der)
    }

    /// Waits, for a bounded time, until the blob and the certificate item just
    /// written can be read back. The login Keychain can answer "not found" for
    /// about 100 ms after a write (#617); a caller that reads or deletes directly
    /// after `loadOrCreate()` must not meet that window.
    private func waitUntilReadable(_ der: Data) {
        let label = self.commonName(ofDER: der)
        for attempt in 1 ... 10 {
            var item: CFTypeRef?
            let certStatus = SecItemCopyMatching([
                kSecClass as String: kSecClassCertificate,
                kSecAttrLabel as String: label,
                kSecReturnRef as String: true,
            ] as CFDictionary, &item)
            do {
                if certStatus == errSecSuccess, try self.readCertificateBlob() == der {
                    return
                }
            } catch {
                self.log.warning("identity.store.readBack.failed", ["error": String(reflecting: error)])
            }
            usleep(useconds_t(10000 * attempt))
        }
        self.log.warning("identity.store.notReadable", ["cn": label])
    }

    private func writeCertificateBlob(_ der: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: Self.certAccount,
        ]
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: der] as CFDictionary)
        if update == errSecSuccess {
            return
        }
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

    /// Removes the certificate blob and every `SecCertificate` item of this
    /// store. Call it while the key is still stored: the key is what finds a
    /// certificate whose blob is gone.
    private func deleteCertificate() {
        // The Keychain labels a certificate with its subject common name and
        // ignores a label given on add, so the delete goes by that name. A class
        // and a label together are a narrow query; a certificate delete is never
        // sent without the label.
        for label in self.storedCertificateLabels() {
            SecItemDelete([
                kSecClass as String: kSecClassCertificate,
                kSecAttrLabel as String: label,
            ] as CFDictionary)
        }
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: Self.certAccount,
        ] as CFDictionary)
    }

    /// The Keychain labels of this store's certificates: the one in the blob,
    /// and every certificate made for the stored key (a certificate replaced
    /// after a stable miss has no blob any more). Only names this module makes.
    private func storedCertificateLabels() -> Set<String> {
        var labels: Set<String> = []
        do {
            if let der = try self.readCertificateBlob() {
                labels.insert(self.commonName(ofDER: der))
            }
        } catch {
            self.log.warning("identity.cleanup.blobRead.failed", ["error": String(reflecting: error)])
        }
        if let publicKeyHash = self.storedKeyPublicKeyHash() {
            var items: CFTypeRef?
            let status = SecItemCopyMatching([
                kSecClass as String: kSecClassCertificate,
                kSecAttrPublicKeyHash as String: publicKeyHash,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll,
            ] as CFDictionary, &items)
            if status == errSecSuccess, let found = items as? [[String: Any]] {
                labels.formUnion(found.compactMap { $0[kSecAttrLabel as String] as? String })
            }
        }
        return labels.filter { $0.hasPrefix(Self.commonNamePrefix) }
    }

    /// The public key hash of the stored key, which the Keychain also records
    /// on each certificate made for that key.
    private func storedKeyPublicKeyHash() -> Data? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: self.keyTag,
            kSecReturnAttributes as String: true,
        ] as CFDictionary, &item)
        guard status == errSecSuccess, let attributes = item as? [String: Any] else {
            return nil
        }
        let hash = attributes[kSecAttrApplicationLabel as String] as? Data
        return hash?.isEmpty == false ? hash : nil
    }

    private func commonName(ofDER der: Data) -> String {
        guard let cert = SecCertificateCreateWithData(nil, der as CFData) else {
            return "bocan-mac-unknown"
        }
        return (SecCertificateCopySubjectSummary(cert) as String?) ?? "bocan-mac-unknown"
    }
}
