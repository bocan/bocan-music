import Foundation
import Observability
import Persistence
import Security

// MARK: - SubsonicCredential

/// The secret stored in the Keychain for one server.
/// Never stored on disk; JSON is only ever written to the Keychain data blob.
struct SubsonicCredential: Codable {
    /// Schema version, for forward-compatible migration.
    var v = 1
    /// Auth kind: "tokenSalt" or "apiKey".
    var kind: String
    /// The actual secret: password (tokenSalt) or API key (apiKey).
    var secret: String
}

// MARK: - SubsonicServerStore

/// Owns the full lifecycle of `SubsonicServer` records: persistence (via
/// `SubsonicServerRepository`) and credentials (via the macOS Keychain).
///
/// **Security contract:**
/// - Credentials are written exclusively to the Keychain under service
///   `io.cloudcauldron.bocan.subsonic`, account `<serverID>`.
/// - `SubsonicServer` value types never carry the secret.
/// - Log messages never include raw credentials; the `AppLogger` redaction
///   layer ensures key names like "password"/"secret" are scrubbed, and we
///   additionally avoid logging credential fields explicitly.
public actor SubsonicServerStore {
    // MARK: - Constants

    private static let keychainService = "io.cloudcauldron.bocan.subsonic"

    // MARK: - Dependencies

    private let repository: SubsonicServerRepository
    private let log = AppLogger.make(.subsonic)

    // MARK: - Init

    public init(repository: SubsonicServerRepository) {
        self.repository = repository
    }

    // MARK: - CRUD

    /// Adds a new server and stores its credential in the Keychain.
    ///
    /// - Parameters:
    ///   - server: The server record (must not carry the secret in any field).
    ///   - secret: The password (`.tokenSalt`) or API key (`.apiKey`).
    ///             This value is written to the Keychain and then discarded.
    public func add(_ server: SubsonicServer, secret: String) async throws {
        let dto = self.toDTO(server)
        // Write Keychain first; if persistence fails we delete the item.
        try self.keychainWrite(server: server, secret: secret)
        do {
            try await self.repository.insert(dto)
        } catch {
            // Roll back the Keychain item to keep them in sync.
            do {
                try self.keychainDelete(account: server.keychainAccount)
            } catch let keychainError {
                self.log.warning("subsonic.store.rollback.keychain.failed", ["error": String(reflecting: keychainError)])
            }
            throw error
        }
        self.log.info("subsonic.store.add", ["id": server.id.uuidString, "name": server.name])
    }

    /// Updates an existing server record. Pass a non-nil `newSecret` only when
    /// the credential has changed.
    public func update(_ server: SubsonicServer, newSecret: String? = nil) async throws {
        if let secret = newSecret {
            try self.keychainWrite(server: server, secret: secret)
        }
        let dto = self.toDTO(server)
        try await self.repository.update(dto)
        self.log.debug("subsonic.store.update", ["id": server.id.uuidString])
    }

    /// Removes the server, its Keychain item, and its metadata cache.
    public func remove(id: UUID) async throws {
        // Fetch so we can get the keychainAccount before deletion.
        if let dto = try await self.repository.fetch(id: id) {
            do {
                try self.keychainDelete(account: dto.keychainAccount)
            } catch {
                self.log.warning("subsonic.store.remove.keychain.failed", ["id": id.uuidString, "error": String(reflecting: error)])
            }
            try await self.repository.deleteCache(serverID: id)
        }
        try await self.repository.delete(id: id)
        self.log.info("subsonic.store.remove", ["id": id.uuidString])
    }

    /// Returns all servers in display order.
    public func fetchAll() async throws -> [SubsonicServer] {
        let dtos = try await self.repository.fetchAll()
        return dtos.compactMap { self.fromDTO($0) }
    }

    /// Returns a single server, or `nil` if not found.
    public func fetch(id: UUID) async throws -> SubsonicServer? {
        guard let dto = try await self.repository.fetch(id: id) else { return nil }
        return self.fromDTO(dto)
    }

    /// Persists a fresh capability snapshot for a server without rewriting the
    /// full record. Used by the capability refresh path (Phase 19 step 16).
    public func updateCapabilities(
        serverID: UUID,
        capabilitiesJSON: Data?,
        lastConnectedAt: Date = Date()
    ) async throws {
        try await self.repository.updateCapabilities(
            id: serverID,
            capabilitiesJSON: capabilitiesJSON,
            lastConnectedAt: lastConnectedAt
        )
    }

    // MARK: - Credential access

    /// Reads the credential secret from the Keychain for `serverID`.
    ///
    /// - Returns: The password or API key string.
    /// - Throws: `SubsonicError.keychain` if the item is absent.
    public func secret(for serverID: UUID) throws -> String {
        let account = serverID.uuidString
        let credential = try self.keychainRead(account: account)
        return credential.secret
    }

    // MARK: - Orphan cleanup

    /// Removes Keychain items whose server row no longer exists in the database.
    /// Safe to call on every app launch.
    public func migrateOrphans() async throws {
        let live = try await self.repository.fetchAll().map(\.keychainAccount)
        let liveSet = Set(live)

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let items = result as? [[CFString: Any]] else { return }

        var orphanCount = 0
        for item in items {
            guard let account = item[kSecAttrAccount] as? String else { continue }
            if !liveSet.contains(account) {
                do {
                    try self.keychainDelete(account: account)
                } catch {
                    self.log.warning("subsonic.store.orphan.keychain.failed", ["account": account, "error": String(reflecting: error)])
                }
                orphanCount += 1
            }
        }
        if orphanCount > 0 {
            self.log.info("subsonic.store.orphans.removed", ["count": orphanCount])
        }
    }

    // MARK: - Persistence → model conversions

    private func toDTO(_ server: SubsonicServer) -> SubsonicServerDTO {
        SubsonicServerDTO(
            id: server.id,
            name: server.name,
            serverURL: server.serverURL,
            authKind: server.authKind.rawValue,
            username: server.username,
            keychainAccount: server.keychainAccount,
            allowSelfSignedTLS: server.allowSelfSignedTLS,
            maxBitrate: server.maxBitrate.storedValue,
            preferredFormat: server.preferredFormat.rawValue,
            precacheNext: server.precacheNext,
            includeInSearch: server.includeInGlobalSearch,
            showInSidebar: server.showInSidebar,
            scrobble: server.scrobble,
            syncStars: server.syncStars,
            syncRatings: server.syncRatings,
            sortIndex: server.sortIndex,
            createdAt: server.createdAt,
            lastConnectedAt: server.lastConnectedAt,
            capabilitiesJSON: server.cachedCapabilitiesJSON
        )
    }

    private func fromDTO(_ dto: SubsonicServerDTO) -> SubsonicServer? {
        guard let authKind = SubsonicAuthKind(rawValue: dto.authKind),
              let format = SubsonicStreamFormat(rawValue: dto.preferredFormat) else {
            self.log.warning(
                "subsonic.store.invalid.dto",
                ["id": dto.id.uuidString, "authKind": dto.authKind]
            )
            return nil
        }
        return SubsonicServer(
            id: dto.id,
            name: dto.name,
            serverURL: dto.serverURL,
            authKind: authKind,
            username: dto.username,
            keychainAccount: dto.keychainAccount,
            allowSelfSignedTLS: dto.allowSelfSignedTLS,
            maxBitrate: SubsonicBitrate(storedValue: dto.maxBitrate),
            preferredFormat: format,
            precacheNext: dto.precacheNext,
            includeInGlobalSearch: dto.includeInSearch,
            showInSidebar: dto.showInSidebar,
            scrobble: dto.scrobble,
            syncStars: dto.syncStars,
            syncRatings: dto.syncRatings,
            sortIndex: dto.sortIndex,
            createdAt: dto.createdAt,
            lastConnectedAt: dto.lastConnectedAt,
            cachedCapabilitiesJSON: dto.capabilitiesJSON
        )
    }

    // MARK: - Keychain helpers

    private func keychainWrite(server: SubsonicServer, secret: String) throws {
        let credential = SubsonicCredential(
            kind: server.authKind.rawValue,
            secret: secret
        )
        let data = try JSONEncoder().encode(credential)
        let account = server.keychainAccount

        // Try an update first; fall back to add.
        let updateQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: account,
        ]
        // Include kSecAttrAccessible on update so credential rotation never
        // silently inherits a different accessibility class (#285).
        let updateAttrs: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttrs as CFDictionary)

        if updateStatus == errSecItemNotFound {
            let addQuery: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: Self.keychainService,
                kSecAttrAccount: account,
                kSecValueData: data,
                // Accessible after first unlock; survives reboots without user present.
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                throw SubsonicError.keychain(addStatus, "add")
            }
        } else if updateStatus != errSecSuccess {
            throw SubsonicError.keychain(updateStatus, "update")
        }
        self.log.debug("subsonic.keychain.write", ["account": account])
    }

    private func keychainRead(account: String) throws -> SubsonicCredential {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw SubsonicError.keychain(status, "read")
        }
        return try JSONDecoder().decode(SubsonicCredential.self, from: data)
    }

    private func keychainDelete(account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Self.keychainService,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SubsonicError.keychain(status, "delete")
        }
        self.log.debug("subsonic.keychain.delete", ["account": account])
    }
}
