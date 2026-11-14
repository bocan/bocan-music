import Foundation

// MARK: - JellyfinBitrate

/// Maximum stream bitrate the client will request from the server.
///
/// Stored as text in `jellyfin_servers.max_bitrate`: `"original"` or a kbps
/// number. Jellyfin wants bits per second, so `bitsPerSecond` converts.
public enum JellyfinBitrate: Sendable, Codable, Hashable {
    case original
    case kbps(Int)

    /// Serialised string used in the database `max_bitrate` column.
    public var storedValue: String {
        switch self {
        case .original:
            "original"

        case let .kbps(value):
            String(value)
        }
    }

    /// Parses the stored string value. Anything unreadable means `.original`.
    public init(storedValue: String) {
        if let value = Int(storedValue), value > 0 {
            self = .kbps(value)
        } else {
            self = .original
        }
    }

    /// The cap in kbps, or `nil` for the original bitrate.
    public var kbps: Int? {
        switch self {
        case .original:
            nil

        case let .kbps(value):
            value
        }
    }

    /// The cap in bits per second, the unit Jellyfin's `audioBitRate` takes.
    public var bitsPerSecond: Int? {
        self.kbps.map { $0 * 1000 }
    }
}

// MARK: - JellyfinStreamFormat

/// Preferred audio format the client will request from the server.
public enum JellyfinStreamFormat: String, Sendable, Codable, Hashable, CaseIterable {
    case original, mp3, opus, aac, flac

    /// The transcode container for this format, or `nil` for the original file.
    public var container: String? {
        self == .original ? nil : self.rawValue
    }

    /// The transcode audio codec for this format, or `nil` for the original file.
    public var audioCodec: String? {
        self == .original ? nil : self.rawValue
    }
}

// MARK: - JellyfinServer

/// A configured Jellyfin server.
///
/// **Security contract**: this struct never carries the access token. The token
/// is held only in the Keychain, keyed by the server `id`. `JellyfinServerStore`
/// is the only layer that reads or writes Keychain items.
public struct JellyfinServer: Identifiable, Hashable, Sendable, Codable {
    // MARK: Properties

    /// Stable identity; also the `id` column in `jellyfin_servers` and the Keychain account.
    public let id: UUID

    /// User-visible display name; unique within the database.
    public var name: String

    /// Base URL of the server (trailing slash stripped on save).
    public var serverURL: URL

    /// The Jellyfin user id (an opaque GUID string) the token belongs to.
    public var userID: String

    /// Account name, shown as "Signed in as". Display only.
    public var username: String?

    /// Client device id sent to the server. Made once, never changed.
    public let deviceID: String

    /// Whether this server's TLS certificate may be self-signed.
    public var allowSelfSignedTLS: Bool

    /// Maximum bitrate to request from the server.
    public var maxBitrate: JellyfinBitrate

    /// Preferred stream format.
    public var preferredFormat: JellyfinStreamFormat

    /// Pre-fetch the next queue item's audio as soon as the current track starts.
    public var precacheNext: Bool

    /// Include this server in the federated global search.
    public var includeInGlobalSearch: Bool

    /// Show this server's subtree in the sidebar.
    public var showInSidebar: Bool

    /// Send play reports to this server.
    public var scrobble: Bool

    /// Mirror star / unstar actions to the server as favourites.
    public var syncStars: Bool

    /// Display order in the sidebar and Settings list.
    public var sortIndex: Int

    /// When the server record was created.
    public var createdAt: Date

    /// Last time a successful ping was received from this server.
    public var lastConnectedAt: Date?

    // MARK: Init

    public init(
        // Memberwise initialiser used across modules; the labels follow the
        // stored-property order, as the Persistence record does.
        // swiftlint:disable:next function_default_parameter_at_end
        id: UUID = UUID(),
        name: String,
        serverURL: URL,
        userID: String,
        username: String? = nil,
        deviceID: String = UUID().uuidString,
        allowSelfSignedTLS: Bool = false,
        maxBitrate: JellyfinBitrate = .original,
        preferredFormat: JellyfinStreamFormat = .original,
        precacheNext: Bool = true,
        includeInGlobalSearch: Bool = true,
        showInSidebar: Bool = true,
        scrobble: Bool = true,
        syncStars: Bool = true,
        sortIndex: Int = 0,
        createdAt: Date = Date(),
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.serverURL = Self.normalise(serverURL)
        self.userID = userID
        self.username = username
        self.deviceID = deviceID
        self.allowSelfSignedTLS = allowSelfSignedTLS
        self.maxBitrate = maxBitrate
        self.preferredFormat = preferredFormat
        self.precacheNext = precacheNext
        self.includeInGlobalSearch = includeInGlobalSearch
        self.showInSidebar = showInSidebar
        self.scrobble = scrobble
        self.syncStars = syncStars
        self.sortIndex = sortIndex
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
    }

    // MARK: Helpers

    /// Returns `url` with any trailing slashes removed.
    static func normalise(_ url: URL) -> URL {
        var text = url.absoluteString
        while text.hasSuffix("/") {
            text.removeLast()
        }
        return URL(string: text) ?? url
    }
}
