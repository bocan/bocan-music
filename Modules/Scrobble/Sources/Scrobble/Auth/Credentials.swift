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

    /// Creates a store whose items are keyed under the Keychain service `service`.
    public init(service: String = Credentials.defaultService) {
        self.service = service
    }

    // MARK: Read

    /// The value stored for `account` as UTF-8 text, or `nil` when there is no
    /// item or its data is not UTF-8. Throws `ScrobbleError.keychain` on any
    /// other Keychain failure.
    public func string(for account: String) throws -> String? {
        guard let data = try self.data(for: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The raw value stored for `account`, or `nil` when there is no item.
    /// Throws `ScrobbleError.keychain` on any other Keychain failure.
    public func data(for account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess {
            return item as? Data
        }
        if status == errSecItemNotFound {
            return nil
        }
        throw ScrobbleError.keychain(status: status, message: Self.message(for: status))
    }

    // MARK: Write

    /// Stores `value` as UTF-8 for `account`, replacing any existing item.
    public func set(_ value: String, for account: String) throws {
        try self.set(Data(value.utf8), for: account)
    }

    /// Stores `value` for `account`: updates the existing item, or adds one
    /// when there is none. Throws `ScrobbleError.keychain` on failure.
    public func set(_ value: Data, for account: String) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: account,
        ]

        // Try to update first; fall back to add.
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = value
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw ScrobbleError.keychain(status: addStatus, message: Self.message(for: addStatus))
            }
            return
        }
        throw ScrobbleError.keychain(status: updateStatus, message: Self.message(for: updateStatus))
    }

    // MARK: Delete

    /// Deletes the item for `account`. An item that is already absent is not
    /// an error; any other Keychain failure throws `ScrobbleError.keychain`.
    public func remove(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            return
        }
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

    /// Creates a store that already holds `seed`, a map of account to UTF-8 value.
    public init(seed: [String: String] = [:]) {
        for (account, value) in seed {
            self.storage[account] = Data(value.utf8)
        }
    }

    /// The value for `account` as UTF-8 text, or `nil` when absent or not UTF-8.
    public func string(for account: String) -> String? {
        self.storage[account].flatMap { String(data: $0, encoding: .utf8) }
    }

    /// The raw value for `account`, or `nil` when absent.
    public func data(for account: String) -> Data? {
        self.storage[account]
    }

    /// Stores `value` as UTF-8 for `account`, replacing any existing value.
    public func set(_ value: String, for account: String) {
        self.storage[account] = Data(value.utf8)
    }

    /// Stores `value` for `account`, replacing any existing value.
    public func set(_ value: Data, for account: String) {
        self.storage[account] = value
    }

    /// Removes the value for `account`; does nothing when it is absent.
    public func remove(account: String) {
        self.storage.removeValue(forKey: account)
    }

    /// Every account that holds a value, in no particular order.
    public func allAccounts() -> [String] {
        Array(self.storage.keys)
    }
}
