import Foundation
import SwiftSonic

// MARK: - SubsonicCapabilities

/// A point-in-time snapshot of what a remote server can do.
///
/// Cached in `SubsonicServer.cachedCapabilitiesJSON` and refreshed whenever the
/// stored snapshot is older than `freshnessInterval` (default 24 h).
public struct SubsonicCapabilities: Sendable, Codable, Hashable {
    // MARK: - Properties

    /// Human-readable server type, e.g. "navidrome", "airsonic-advanced".
    public var serverType: String?

    /// The server's own version string, e.g. "0.50.2".
    public var serverVersion: String?

    /// The Subsonic API version the server speaks, e.g. "1.16.1".
    public var apiVersion: String?

    /// `true` when the server advertises the OpenSubsonic extensions envelope.
    public var isOpenSubsonic: Bool

    /// Server supports the `getLyricsBySongId` OpenSubsonic extension.
    public var supportsLyricsBySongId: Bool

    /// Server supports `apiKeyAuthentication` OpenSubsonic extension.
    public var supportsApiKey: Bool

    /// Server hosts podcasts (`getPodcasts` available).
    public var supportsPodcasts: Bool

    /// Server has internet radio stations (`getInternetRadioStations` available).
    public var supportsInternetRadio: Bool

    /// Server supports play-queue bookmarks (`getBookmarks` available).
    public var supportsBookmarks: Bool

    /// Server supports jukebox mode (`jukeboxControl` available).
    public var supportsJukebox: Bool

    /// Server supports share links (`getShares` available).
    public var supportsShares: Bool

    /// `getRandomSongs` accepts a `genre` parameter.
    public var supportsRandomSongsByGenre: Bool

    /// Wall-clock time this snapshot was fetched.
    public var fetchedAt: Date

    // MARK: - Freshness

    /// Snapshots older than this are refreshed on the next API call.
    public static let freshnessInterval: TimeInterval = 86400 // 24 h

    /// `true` if the snapshot should be refreshed before being relied upon.
    public var isStale: Bool {
        Date().timeIntervalSince(self.fetchedAt) > Self.freshnessInterval
    }

    // MARK: - Init

    public init(
        serverType: String? = nil,
        serverVersion: String? = nil,
        apiVersion: String? = nil,
        isOpenSubsonic: Bool = false,
        supportsLyricsBySongId: Bool = false,
        supportsApiKey: Bool = false,
        supportsPodcasts: Bool = false,
        supportsInternetRadio: Bool = false,
        supportsBookmarks: Bool = false,
        supportsJukebox: Bool = false,
        supportsShares: Bool = false,
        supportsRandomSongsByGenre: Bool = false,
        fetchedAt: Date = Date()
    ) {
        self.serverType = serverType
        self.serverVersion = serverVersion
        self.apiVersion = apiVersion
        self.isOpenSubsonic = isOpenSubsonic
        self.supportsLyricsBySongId = supportsLyricsBySongId
        self.supportsApiKey = supportsApiKey
        self.supportsPodcasts = supportsPodcasts
        self.supportsInternetRadio = supportsInternetRadio
        self.supportsBookmarks = supportsBookmarks
        self.supportsJukebox = supportsJukebox
        self.supportsShares = supportsShares
        self.supportsRandomSongsByGenre = supportsRandomSongsByGenre
        self.fetchedAt = fetchedAt
    }

    // MARK: - Factory from SwiftSonic

    /// Converts a `ServerCapabilities` value from SwiftSonic into our model.
    public static func from(_ caps: ServerCapabilities) -> Self {
        SubsonicCapabilities(
            serverType: caps.serverType,
            serverVersion: caps.serverVersion,
            apiVersion: caps.apiVersion,
            isOpenSubsonic: caps.isOpenSubsonic,
            supportsLyricsBySongId: caps.supports(.songLyrics),
            supportsApiKey: caps.supports(.apiKeyAuthentication),
            supportsPodcasts: caps.supports("podcasts"),
            supportsInternetRadio: caps.supports("internetRadio"),
            supportsBookmarks: caps.supports("bookmarks"),
            supportsJukebox: caps.supports("jukebox"),
            supportsShares: caps.supports("shares"),
            supportsRandomSongsByGenre: caps.supports("randomSongsByGenre"),
            fetchedAt: Date()
        )
    }

    // MARK: - Mutable capability override

    /// Marks a capability as unsupported when the server lied about supporting it.
    /// Used in the "capability lie" gotcha handler.
    public mutating func markUnsupported(_ feature: String) {
        switch feature {
        case "podcasts": self.supportsPodcasts = false
        case "internetRadio": self.supportsInternetRadio = false
        case "bookmarks": self.supportsBookmarks = false
        case "jukebox": self.supportsJukebox = false
        case "shares": self.supportsShares = false
        case "songLyrics": self.supportsLyricsBySongId = false
        case "apiKeyAuthentication": self.supportsApiKey = false
        case "randomSongsByGenre": self.supportsRandomSongsByGenre = false
        default: break
        }
    }
}
