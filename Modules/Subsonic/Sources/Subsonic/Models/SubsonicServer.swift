import Foundation

// MARK: - SubsonicAuthKind

/// Authentication mechanism the client uses when talking to this server.
public enum SubsonicAuthKind: String, Sendable, Codable, Hashable, CaseIterable {
    /// Legacy Subsonic token-salt: a per-request HMAC of the password + random salt.
    /// Used by classic Subsonic, Airsonic, and Navidrome by default.
    case tokenSalt
    /// OpenSubsonic `apiKeyAuthentication` extension: a long-lived API key replaces
    /// username + password entirely (no salt rotation).
    case apiKey
}

// MARK: - SubsonicBitrate

/// Maximum stream bitrate the client will request from the server.
public enum SubsonicBitrate: Sendable, Codable, Hashable {
    case original
    case kbps(Int)

    /// Serialised string used in the database `max_bitrate` column.
    public var storedValue: String {
        switch self {
        case .original: "original"
        case let .kbps(n): String(n)
        }
    }

    /// Parses the stored string value.
    public init(storedValue: String) {
        if storedValue == "original" {
            self = .original
        } else if let n = Int(storedValue) {
            self = .kbps(n)
        } else {
            self = .original
        }
    }

    /// Value to pass as `maxBitRate` to `SwiftSonicClient.streamURL`.
    public var intValue: Int? {
        switch self {
        case .original: nil
        case let .kbps(n): n
        }
    }
}

// MARK: - SubsonicStreamFormat

/// Preferred audio format the client will request from the server.
public enum SubsonicStreamFormat: String, Sendable, Codable, Hashable, CaseIterable {
    case original, mp3, opus, aac, flac

    /// Value to pass as `format` to `SwiftSonicClient.streamURL`.
    public var requestValue: String? {
        self == .original ? nil : self.rawValue
    }
}

// MARK: - SubsonicServer

/// A configured Subsonic-compatible remote server.
///
/// **Security contract**: this struct never carries the credential secret.
/// Passwords and API keys are held exclusively in the Keychain, keyed by
/// `keychainAccount`. The `SubsonicServerStore` is the only layer that reads
/// or writes Keychain items.
public struct SubsonicServer: Identifiable, Hashable, Sendable, Codable {
    // MARK: Properties

    /// Stable identity; also the `id` column in `subsonic_servers`.
    public let id: UUID

    /// User-visible display name; unique within the database.
    public var name: String

    /// Base URL of the server (trailing slash stripped on save).
    public var serverURL: URL

    /// Authentication mechanism.
    public var authKind: SubsonicAuthKind

    /// Username for `.tokenSalt` auth; `nil` for `.apiKey` auth.
    public var username: String?

    /// Opaque key used to look up the credential in the Keychain.
    /// Value is `<serverID>` under service `io.cloudcauldron.bocan.subsonic`.
    public var keychainAccount: String

    /// Whether this server's TLS certificate may be self-signed.
    /// When `true` an amber warning is shown in Settings.
    public var allowSelfSignedTLS: Bool

    /// Maximum bitrate to request from the server.
    public var maxBitrate: SubsonicBitrate

    /// Preferred stream format.
    public var preferredFormat: SubsonicStreamFormat

    /// Pre-fetch the next queue item's audio as soon as the current track starts.
    public var precacheNext: Bool

    /// Include this server in the federated global search.
    public var includeInGlobalSearch: Bool

    /// Show this server's subtree in the sidebar.
    public var showInSidebar: Bool

    /// Send completed-play events to this server's `/scrobble` endpoint.
    public var scrobble: Bool

    /// Mirror star / unstar actions to the server.
    public var syncStars: Bool

    /// Mirror track ratings to the server.
    public var syncRatings: Bool

    /// Display order in the sidebar and Settings list.
    public var sortIndex: Int

    /// When the server record was created.
    public var createdAt: Date

    /// Last time a successful ping was received from this server.
    public var lastConnectedAt: Date?

    /// JSON-encoded `SubsonicCapabilities` snapshot.
    /// Refreshed lazily when older than 24 h.
    public var cachedCapabilitiesJSON: Data?

    // MARK: Init

    public init(
        id: UUID = UUID(),
        name: String,
        serverURL: URL,
        authKind: SubsonicAuthKind,
        username: String? = nil,
        keychainAccount: String? = nil,
        allowSelfSignedTLS: Bool = false,
        maxBitrate: SubsonicBitrate = .original,
        preferredFormat: SubsonicStreamFormat = .original,
        precacheNext: Bool = true,
        includeInGlobalSearch: Bool = true,
        showInSidebar: Bool = true,
        scrobble: Bool = true,
        syncStars: Bool = true,
        syncRatings: Bool = true,
        sortIndex: Int = 0,
        createdAt: Date = Date(),
        lastConnectedAt: Date? = nil,
        cachedCapabilitiesJSON: Data? = nil
    ) {
        self.id = id
        self.name = name
        // Strip trailing slashes to avoid double-slash bugs in endpoint construction.
        self.serverURL = Self.normalise(serverURL)
        self.authKind = authKind
        self.username = username
        self.keychainAccount = keychainAccount ?? id.uuidString
        self.allowSelfSignedTLS = allowSelfSignedTLS
        self.maxBitrate = maxBitrate
        self.preferredFormat = preferredFormat
        self.precacheNext = precacheNext
        self.includeInGlobalSearch = includeInGlobalSearch
        self.showInSidebar = showInSidebar
        self.scrobble = scrobble
        self.syncStars = syncStars
        self.syncRatings = syncRatings
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
        self.cachedCapabilitiesJSON = cachedCapabilitiesJSON
    }

    // MARK: Helpers

    /// Returns `url` with any trailing slashes removed.
    private static func normalise(_ url: URL) -> URL {
        var s = url.absoluteString
        while s.hasSuffix("/") {
            s.removeLast()
        }
        return URL(string: s) ?? url
    }
}
