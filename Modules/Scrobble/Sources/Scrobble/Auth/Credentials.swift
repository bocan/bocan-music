import Foundation
import Security

// MARK: - Credentials

/// Small wrapper around the macOS keychain (`SecItem` API) for storing
/// per-provider tokens. Stores values as generic passwords keyed by
/// (service, account); `service` is hard-coded to our bundle reverse-DNS so
/// keychain entries stay namespaced to the app.
///
/// **Why an actor?** All `SecItem*` calls are thread-safe but we want to
/// serialise reads/writes per account so callers don't have to worry about
/// races between, say, a "rotate session key" path and a normal "submit"
/// path reading the previous value.
public actor Credentials {
    /// Reverse-DNS service identifier.
    public static let defaultService = "io.cloudcauldron.bocan.scrobble"

    private let service: String

    public init(service: String = Credentials.defaultService) {
        self.service = service
    }

    // MARK: Read

    public func string(for account: String) throws -> String? {
        guard let data = try self.data(for: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func data(for account: String) throws -> Data? {
        var query: [String: Any] = [
            kSecUseDataProtectionKeychain as String: true,
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        query[kSecAttrSynchronizable as String] = false

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess { return item as? Data }
        // Lazy migration from the legacy file-based Keychain: tokens written before the
        // data-protection switch still live there. Move them across on first access.
        if status == errSecItemNotFound, let legacy = try self.legacyData(for: account) {
            try? self.set(legacy, for: account)
            self.legacyDelete(account: account)
            return legacy
        }
        if status == errSecItemNotFound { return nil }
        throw ScrobbleError.keychain(status: status, message: Self.message(for: status))
    }

    /// Reads a token from the legacy file-based Keychain, or `nil` if absent.
    private func legacyData(for account: String) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        query[kSecAttrSynchronizable as String] = false

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw ScrobbleError.keychain(status: status, message: Self.message(for: status))
        }
        return item as? Data
    }

    private func legacyDelete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: account,
        ]
        _ = SecItemDelete(query as CFDictionary)
    }

    // MARK: Write

    public func set(_ value: String, for account: String) throws {
        try self.set(Data(value.utf8), for: account)
    }

    public func set(_ value: Data, for account: String) throws {
        let baseQuery: [String: Any] = [
            kSecUseDataProtectionKeychain as String: true,
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: account,
        ]

        // Try to update first; fall back to add.
        let updateAttrs: [String: Any] = [
            kSecValueData as String: value,
            // Accessible after first unlock so the offline drain worker can read it
            // in the background; device-only so it never syncs via iCloud Keychain.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return }

        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = value
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            addQuery[kSecAttrSynchronizable as String] = false
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw ScrobbleError.keychain(status: addStatus, message: Self.message(for: addStatus))
            }
            return
        }
        throw ScrobbleError.keychain(status: updateStatus, message: Self.message(for: updateStatus))
    }

    // MARK: Delete

    public func remove(account: String) throws {
        let query: [String: Any] = [
            kSecUseDataProtectionKeychain as String: true,
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        // Also clear any straggler left in the legacy store.
        self.legacyDelete(account: account)
        if status == errSecSuccess || status == errSecItemNotFound { return }
        throw ScrobbleError.keychain(status: status, message: Self.message(for: status))
    }

    // MARK: Errors

    private static func message(for status: OSStatus) -> String {
        if let cfMessage = SecCopyErrorMessageString(status, nil) {
            return cfMessage as String
        }
        return "OSStatus \(status)"
    }
}

// MARK: - InMemoryCredentials

/// Test fixture so unit tests don't touch the real keychain.
public actor InMemoryCredentials {
    private var storage: [String: Data] = [:]

    public init(seed: [String: String] = [:]) {
        for (account, value) in seed {
            self.storage[account] = Data(value.utf8)
        }
    }

    public func string(for account: String) -> String? {
        self.storage[account].flatMap { String(data: $0, encoding: .utf8) }
    }

    public func data(for account: String) -> Data? {
        self.storage[account]
    }

    public func set(_ value: String, for account: String) {
        self.storage[account] = Data(value.utf8)
    }

    public func set(_ value: Data, for account: String) {
        self.storage[account] = value
    }

    public func remove(account: String) {
        self.storage.removeValue(forKey: account)
    }

    public func allAccounts() -> [String] {
        Array(self.storage.keys)
    }
}
