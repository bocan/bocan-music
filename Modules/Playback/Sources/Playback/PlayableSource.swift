import Foundation

// MARK: - PlayableSource

/// Identifies where the audio for a `QueueItem` actually lives.
///
/// This is the indirection that lets the playback engine treat local
/// bookmarked files and remote Subsonic streams uniformly. A
/// `PlayableResolver` (added alongside `SubsonicStreamCache` in step 6)
/// converts every `PlayableSource` into a local file URL the AudioEngine
/// can decode, so ReplayGain, gapless scheduling, the EQ chain, and the
/// visualizer pipeline never need a remote-specific code path.
///
/// ## Encoding
/// `Codable` uses a discriminated representation keyed on `kind`:
/// ```json
/// { "kind": "localBookmark", "bookmark": "<base64>" }
/// { "kind": "subsonic", "serverID": "<uuid>", "songID": "tr-1234" }
/// { "kind": "internetRadio", "streamURL": "<absolute URL>" }
/// ```
/// Legacy persisted queues (v1 schema) lack this field entirely; the
/// restore path in `QueuePersistence` upgrades those to
/// `.localBookmark(Data())` and re-saves under the v2 key.
public enum PlayableSource: Sendable, Hashable, Codable {
    /// A locally accessible file referenced by a security-scoped bookmark.
    /// An empty `Data()` value is legal and means "fall back to the
    /// `QueueItem.fileURL` string"; that fallback exists for items
    /// restored from a v1 queue blob where bookmarks were intentionally
    /// stripped to keep the JSON payload small.
    case localBookmark(Data)

    /// A track that streams from a configured Subsonic / Navidrome
    /// server. The pair (`serverID`, `songID`) is enough for the
    /// `SubsonicStreamCache` to produce a local cache-file URL.
    case subsonic(serverID: UUID, songID: String)

    /// An internet radio station: a live HTTP / HTTPS stream identified
    /// by its absolute URL. The audio engine reads the stream directly
    /// via FFmpeg — no bookmark, no Subsonic stream cache. Live streams
    /// have no fixed duration and don't support seek; the queue treats
    /// the source as a single "track" that plays until the user stops
    /// it or the network drops.
    case internetRadio(streamURL: URL)

    // MARK: - Convenience

    /// `true` when the source must be streamed from a remote server.
    public var isRemote: Bool {
        switch self {
        case .localBookmark: false
        case .subsonic, .internetRadio: true
        }
    }

    /// `true` when the source is a live (open-ended) stream rather than
    /// a finite track. Used by scrobble / history / now-playing paths to
    /// skip duration-based logic.
    public var isLiveStream: Bool {
        switch self {
        case .localBookmark, .subsonic: false
        case .internetRadio: true
        }
    }

    /// The server ID, when the source is `.subsonic`. `nil` for local sources.
    public var subsonicServerID: UUID? {
        if case let .subsonic(serverID, _) = self { return serverID }
        return nil
    }

    /// The Subsonic song ID, when the source is `.subsonic`. `nil` for local sources.
    public var subsonicSongID: String? {
        if case let .subsonic(_, songID) = self { return songID }
        return nil
    }

    /// The stream URL, when the source is `.internetRadio`. `nil` otherwise.
    public var internetRadioURL: URL? {
        if case let .internetRadio(url) = self { return url }
        return nil
    }

    // MARK: - Codable

    private enum Kind: String, Codable {
        case localBookmark
        case subsonic
        case internetRadio
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case bookmark
        case serverID
        case songID
        case streamURL
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .localBookmark:
            let data = try container.decodeIfPresent(Data.self, forKey: .bookmark) ?? Data()
            self = .localBookmark(data)
        case .subsonic:
            let serverID = try container.decode(UUID.self, forKey: .serverID)
            let songID = try container.decode(String.self, forKey: .songID)
            self = .subsonic(serverID: serverID, songID: songID)
        case .internetRadio:
            let url = try container.decode(URL.self, forKey: .streamURL)
            self = .internetRadio(streamURL: url)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .localBookmark(data):
            try container.encode(Kind.localBookmark, forKey: .kind)
            if !data.isEmpty {
                try container.encode(data, forKey: .bookmark)
            }
        case let .subsonic(serverID, songID):
            try container.encode(Kind.subsonic, forKey: .kind)
            try container.encode(serverID, forKey: .serverID)
            try container.encode(songID, forKey: .songID)
        case let .internetRadio(url):
            try container.encode(Kind.internetRadio, forKey: .kind)
            try container.encode(url, forKey: .streamURL)
        }
    }
}
