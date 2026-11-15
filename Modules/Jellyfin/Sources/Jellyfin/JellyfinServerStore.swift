import Foundation
import Observability
import Persistence
import Security

// MARK: - JellyfinCredential

/// The secret stored in the Keychain for one server: the access token.
/// Never stored on disk. The JSON is only ever written to the Keychain data blob.
struct JellyfinCredential: Codable {
    /// Schema version, for forward-compatible migration.
    var version = 1
    /// Always `"accessToken"`. The password is used once and never stored.
    var kind = "accessToken"
    /// The Jellyfin access token.
    var secret: String

    /// The stored blob spells the schema version `v`; the key must not change,
    /// or credentials already in the Keychain stop decoding.
    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case kind
        case secret
    }
}

// MARK: - JellyfinServerStore

/// Owns the full lifecycle of `JellyfinServer` records: persistence (through
/// `JellyfinServerRepository`) and the access token (through the macOS Keychain).
///
/// **Security contract:**
/// - The token is written only to the Keychain, under service
///   `io.cloudcauldron.bocan.jellyfin`, account `<serverID>`.
/// - `JellyfinServer` value types never carry the token.
/// - Log lines never include the token. `AppLogger` redaction scrubs key names
///   such as "secret", and no line names the field in the first place.
public actor JellyfinServerStore {
    // MARK: - Constants

    static let keychainService = "io.cloudcauldron.bocan.jellyfin"

    /// How many times a "not found" read is tried again. With the growing wait,
    /// the last read is 300 ms after the first miss; the misses measured for
    /// #617 ended within 100 ms.
    private static let rereadAttempts = 5

    // MARK: - Dependencies

    private let repository: JellyfinServerRepository
    private let keychainService: String
    private let log = AppLogger.make(.jellyfin)

    // MARK: - Init

    /// Creates a store whose server rows live in `repository`. Tokens always go
    /// to the Keychain, whatever repository is passed.
    public init(repository: JellyfinServerRepository) {
        self.repository = repository
        self.keychainService = Self.keychainService
    }

    /// Test seam: the same store with its own Keychain service name, so a test
    /// never touches a real server's item. Public so the Settings tests in `UI`
    /// can run the add flow against their own service name. The app never calls it.
    public init(repository: JellyfinServerRepository, keychainService: String) {
        self.repository = repository
        self.keychainService = keychainService
    }

    // MARK: - CRUD

    /// Adds a new server and stores its access token in the Keychain.
    ///
    /// The token is written first. If the database write fails, the Keychain
    /// item is removed again so the two stay in step.
    public func add(_ server: JellyfinServer, session: JellyfinSession) async throws {
        try self.keychainWrite(account: server.id.uuidString, token: session.accessToken)
        do {
            try await self.repository.insert(self.toDTO(server))
        } catch {
            do {
                try self.keychainDelete(account: server.id.uuidString)
            } catch {
                self.log.warning("jellyfin.store.rollback.keychain.failed", ["error": String(reflecting: error)])
            }
            throw error
        }
        self.log.info("jellyfin.store.add", ["id": server.id.uuidString, "name": server.name])
    }

    /// Updates an existing server record. Pass a `newSession` only after the
    /// user signed in again; its token replaces the stored one.
    public func update(_ server: JellyfinServer, newSession: JellyfinSession? = nil) async throws {
        if let session = newSession {
            try self.keychainWrite(account: server.id.uuidString, token: session.accessToken)
        }
        try await self.repository.update(self.toDTO(server))
        self.log.debug("jellyfin.store.update", ["id": server.id.uuidString])
    }

    /// Removes the server, its Keychain item and its metadata cache.
    public func remove(id: UUID) async throws {
        if try await self.repository.fetch(id: id) != nil {
            do {
                try self.keychainDelete(account: id.uuidString)
            } catch {
                self.log.warning("jellyfin.store.remove.keychain.failed", ["id": id.uuidString, "error": String(reflecting: error)])
            }
            try await self.repository.deleteCache(serverID: id)
        }
        try await self.repository.delete(id: id)
        self.log.info("jellyfin.store.remove", ["id": id.uuidString])
    }

    /// Returns all servers in display order.
    public func fetchAll() async throws -> [JellyfinServer] {
        try await self.repository.fetchAll().map { self.fromDTO($0) }
    }

    /// Returns a single server, or `nil` if not found.
    public func fetch(id: UUID) async throws -> JellyfinServer? {
        try await self.repository.fetch(id: id).map { self.fromDTO($0) }
    }

    /// Records a successful ping without rewriting the whole row.
    public func updateLastConnected(serverID: UUID, at date: Date = Date()) async throws {
        try await self.repository.updateLastConnected(id: serverID, at: date)
    }

    // MARK: - Credential access

    /// Reads the access token for `serverID`.
    ///
    /// An item written a moment ago can read as "not found" while other
    /// Keychain writes are in progress (docs/GOTCHAS.md), so a miss is read
    /// again with a growing wait before it is reported.
    ///
    /// - Throws: `JellyfinError.keychain` if the item is absent.
    func accessToken(for serverID: UUID) async throws -> String {
        try await self.settledKeychainRead(account: serverID.uuidString).secret
    }

    // MARK: - Orphan cleanup

    /// Removes Keychain items whose server row no longer exists in the database.
    /// Safe to call on every app launch.
    public func migrateOrphans() async throws {
        let live = try await Set(self.repository.fetchAll().map(\.id.uuidString))
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: self.keychainService,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[CFString: Any]] else { return }

        var removed = 0
        for item in items {
            guard let account = item[kSecAttrAccount] as? String, !live.contains(account) else { continue }
            do {
                try self.keychainDelete(account: account)
                removed += 1
            } catch {
                self.log.warning("jellyfin.store.orphan.keychain.failed", ["account": account, "error": String(reflecting: error)])
            }
        }
        if removed > 0 {
            self.log.info("jellyfin.store.orphans.removed", ["count": removed])
        }
    }

    // MARK: - Persistence <-> model conversions

    private func toDTO(_ server: JellyfinServer) -> JellyfinServerDTO {
        JellyfinServerDTO(
            id: server.id,
            name: server.name,
            serverURL: server.serverURL,
            userID: server.userID,
            username: server.username,
            deviceID: server.deviceID,
            allowSelfSignedTLS: server.allowSelfSignedTLS,
            maxBitrate: server.maxBitrate.storedValue,
            preferredFormat: server.preferredFormat.rawValue,
            precacheNext: server.precacheNext,
            includeInSearch: server.includeInGlobalSearch,
            showInSidebar: server.showInSidebar,
            scrobble: server.scrobble,
            syncStars: server.syncStars,
            sortIndex: server.sortIndex,
            createdAt: server.createdAt,
            lastConnectedAt: server.lastConnectedAt
        )
    }

    /// An unknown `preferred_format` (a newer build wrote it) reads as `.original`
    /// and is logged, so one odd value never hides a server.
    private func fromDTO(_ dto: JellyfinServerDTO) -> JellyfinServer {
        let format = JellyfinStreamFormat(rawValue: dto.preferredFormat) ?? {
            self.log.warning("jellyfin.store.unknown.format", ["id": dto.id.uuidString, "format": dto.preferredFormat])
            return .original
        }()
        return JellyfinServer(
            id: dto.id,
            name: dto.name,
            serverURL: dto.serverURL,
            userID: dto.userID,
            username: dto.username,
            deviceID: dto.deviceID,
            allowSelfSignedTLS: dto.allowSelfSignedTLS,
            maxBitrate: JellyfinBitrate(storedValue: dto.maxBitrate),
            preferredFormat: format,
            precacheNext: dto.precacheNext,
            includeInGlobalSearch: dto.includeInSearch,
            showInSidebar: dto.showInSidebar,
            scrobble: dto.scrobble,
            syncStars: dto.syncStars,
            sortIndex: dto.sortIndex,
            createdAt: dto.createdAt,
            lastConnectedAt: dto.lastConnectedAt
        )
    }

    // MARK: - Keychain helpers

    // The token lives in the login (file-based) Keychain, not the
    // data-protection Keychain, as Subsonic's credential does. No
    // `kSecAttrAccessible*` is set: those classes are undefined on the macOS
    // file Keychain and caused intermittent read failures (TN3137).

    private func keychainWrite(account: String, token: String) throws {
        let data = try JSONEncoder().encode(JellyfinCredential(secret: token))
        let match: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: self.keychainService,
            kSecAttrAccount: account,
        ]
        let updateStatus = SecItemUpdate(match as CFDictionary, [kSecValueData: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var add = match
            add[kSecValueData] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                self.log.error("jellyfin.keychain.add.failed", ["status": Int(addStatus), "account": account])
                throw JellyfinError.keychain(addStatus, "add")
            }
        } else if updateStatus != errSecSuccess {
            self.log.error("jellyfin.keychain.update.failed", ["status": Int(updateStatus), "account": account])
            throw JellyfinError.keychain(updateStatus, "update")
        }
        self.log.debug("jellyfin.keychain.write", ["account": account])
    }

    /// Reads the credential, and on "not found" reads again with a growing wait.
    /// Throws "not found" only when every read misses; any other status throws at once.
    private func settledKeychainRead(account: String) async throws -> JellyfinCredential {
        var read = self.keychainCopy(account: account)
        var attempt = 0
        while read.status == errSecItemNotFound, attempt < Self.rereadAttempts {
            attempt += 1
            try await Task.sleep(for: .milliseconds(20 * attempt))
            read = self.keychainCopy(account: account)
        }
        guard let data = read.data else {
            self.log.error("jellyfin.keychain.read.failed", ["status": Int(read.status), "account": account, "attempts": attempt])
            throw JellyfinError.keychain(read.status, "read")
        }
        if attempt > 0 {
            self.log.debug("jellyfin.keychain.read.settled", ["account": account, "attempt": attempt])
        }
        do {
            return try JSONDecoder().decode(JellyfinCredential.self, from: data)
        } catch {
            self.log.error("jellyfin.keychain.decode.failed", ["account": account])
            throw JellyfinError.keychain(errSecDecode, "decode")
        }
    }

    /// One Keychain read. `data` is nil exactly when the read failed; a success
    /// without data reports `errSecDecode`.
    private func keychainCopy(account: String) -> (status: OSStatus, data: Data?) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: self.keychainService,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return (status == errSecSuccess ? errSecDecode : status, nil)
        }
        return (status, data)
    }

    private func keychainDelete(account: String) throws {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: self.keychainService,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw JellyfinError.keychain(status, "delete")
        }
        self.log.debug("jellyfin.keychain.delete", ["account": account])
    }
}
