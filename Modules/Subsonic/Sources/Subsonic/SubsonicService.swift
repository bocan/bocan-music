import Foundation
import Observability
import SwiftSonic

// MARK: - SubsonicMetricsRelay

/// Bridges `SwiftSonicRequestEvent` metrics into Bòcan's observability layer.
///
/// Pass an instance as `metricsCollector:` when building each `SwiftSonicClient`.
/// This gives us per-endpoint duration tracking, retry visibility, and failure
/// logging — all surfaced in Console.app and Instruments via `os.Logger`.
private final class SubsonicMetricsRelay: SwiftSonicMetricsCollector, @unchecked Sendable {
    let serverName: String
    let log: AppLogger

    init(serverName: String) {
        self.serverName = serverName
        self.log = AppLogger.make(.subsonic)
    }

    func record(_ event: SwiftSonicRequestEvent) {
        switch event {
        case let .started(endpoint, _):
            self.log.trace(
                "subsonic.request.start",
                ["server": self.serverName, "endpoint": endpoint]
            )
        case let .succeeded(endpoint, _, duration):
            self.log.debug(
                "subsonic.request.ok",
                ["server": self.serverName, "endpoint": endpoint, "ms": Int(duration * 1000)]
            )
        case let .failed(endpoint, _, error, attempt):
            self.log.warning(
                "subsonic.request.fail",
                [
                    "server": self.serverName,
                    "endpoint": endpoint,
                    "attempt": attempt,
                    "err": error.localizedDescription,
                ]
            )
        case let .retryScheduled(endpoint, attempt, delay):
            self.log.info(
                "subsonic.request.retry",
                [
                    "server": self.serverName,
                    "endpoint": endpoint,
                    "attempt": attempt + 1,
                    "delay_ms": Int(delay * 1000),
                ]
            )
        }
    }
}

// MARK: - TrustBypassTransport

/// A custom `HTTPTransport` that allows a single named host to present a
/// self-signed TLS certificate. The exemption is host-scoped — no global
/// policy is changed.
private final class TrustBypassTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession
    private let host: String

    init(host: String) {
        self.host = host
        let config = URLSessionConfiguration.ephemeral
        self.session = URLSession(
            configuration: config,
            delegate: HostTrustDelegate(host: host),
            delegateQueue: nil
        )
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

private final class HostTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let host: String
    init(host: String) {
        self.host = host
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == self.host,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

// MARK: - SubsonicService

/// Central actor owning a pool of `SwiftSonicClient` instances — one per
/// configured server.
///
/// ## Observability
/// Every client is built with:
/// - `logSubsystem: "io.cloudcauldron.bocan"` so all HTTP activity appears in
///   Console.app under the `SwiftSonicClient` category.
/// - A `SubsonicMetricsRelay` collector that forwards per-endpoint timing and
///   retry events into the `subsonic` `os.Logger` category.
///
/// ## Security
/// Stream and cover-art URLs are produced via `nonisolated` methods on
/// `SwiftSonicClient`; they embed per-request tokens. **Never log these URLs**
/// as they carry the hash token. The SwiftSonic built-in logger redacts them,
/// and we never call `print` or `AppLogger` on them.
public actor SubsonicService {
    /// Identifier sent as the Subsonic `c` query parameter on every request.
    /// Kept ASCII-only so it appears unencoded in server-side client lists
    /// (e.g. Navidrome's "Clients" admin page).
    static let clientName = "Bocan"

    // MARK: - Types

    private struct ClientEntry {
        let client: SwiftSonicClient
        var capabilities: SubsonicCapabilities?
    }

    // MARK: - State

    private var clients: [UUID: ClientEntry] = [:]
    private let store: SubsonicServerStore
    private let log = AppLogger.make(.subsonic)
    private var (capabilityStream, capabilityContinuation) = AsyncStream<UUID>.makeStream()

    // MARK: - Init

    public init(store: SubsonicServerStore) {
        self.store = store
    }

    /// Broadcasts server IDs whose advertised capabilities have changed since
    /// the previously persisted snapshot. The UI subscribes here to redraw
    /// the sidebar when a server upgrade unlocks new sections (Phase 19 step
    /// 16). Multiple subscribers are not supported — wrap in a fan-out if you
    /// need more than one consumer.
    public var capabilityUpdates: AsyncStream<UUID> {
        self.capabilityStream
    }

    // MARK: - Client pool management

    /// Rebuilds the entire client pool from the current server list.
    /// Call once on app start, and again whenever a server is added/edited/removed.
    public func reloadClients() async throws {
        let servers = try await self.store.fetchAll()
        self.clients = [:]
        for server in servers {
            try await self.buildClient(for: server)
        }
        self.log.info("subsonic.service.reloaded", ["count": servers.count])
    }

    /// Inserts or replaces the client for a single server.
    /// Use after `SubsonicServerStore.add` or `SubsonicServerStore.update`.
    public func refreshClient(for server: SubsonicServer) async throws {
        try await self.buildClient(for: server)
        self.log.debug("subsonic.service.client.refresh", ["id": server.id.uuidString])
    }

    /// Removes the client for a deleted server.
    public func removeClient(for serverID: UUID) {
        self.clients.removeValue(forKey: serverID)
        self.log.debug("subsonic.service.client.remove", ["id": serverID.uuidString])
    }

    // MARK: - System

    /// Pings the server; throws `SubsonicError` on failure.
    public func ping(serverID: UUID) async throws {
        let client = try self.requireClient(serverID)
        do {
            try await client.ping()
            self.log.debug("subsonic.ping.ok", ["id": serverID.uuidString])
        } catch let e as SwiftSonicError {
            throw SubsonicError.transport(e)
        }
    }

    // MARK: - Capabilities

    /// Loads (or returns the cached) capabilities for a server.
    /// If the stored snapshot is stale (>24 h) a fresh fetch is performed.
    public func loadCapabilities(serverID: UUID) async throws -> SubsonicCapabilities {
        let client = try self.requireClient(serverID)

        // Return cached if still fresh.
        if let cached = self.clients[serverID]?.capabilities, !cached.isStale {
            return cached
        }
        do {
            let raw = try await client.loadCapabilities()
            let caps = SubsonicCapabilities.from(raw)
            let previous = try? await self.persistedCapabilities(serverID: serverID)
            self.clients[serverID]?.capabilities = caps
            try? await self.persistCapabilities(caps, serverID: serverID)
            if previous?.hasSameCapabilityFlags(as: caps) != true {
                self.capabilityContinuation.yield(serverID)
            }
            self.log.info(
                "subsonic.capabilities.loaded",
                [
                    "id": serverID.uuidString,
                    "type": caps.serverType ?? "unknown",
                    "version": caps.serverVersion ?? "?",
                    "openSubsonic": caps.isOpenSubsonic,
                ]
            )
            return caps
        } catch let e as SwiftSonicError {
            throw SubsonicError.transport(e)
        }
    }

    /// Forces a fresh capability fetch, bypassing the staleness check.
    /// Also bypasses the SwiftSonic client's own capability cache so a real
    /// network refetch happens — required for capability-change detection
    /// after a server upgrade (Phase 19 step 16).
    public func refreshCapabilities(serverID: UUID) async throws -> SubsonicCapabilities {
        let client = try self.requireClient(serverID)
        self.clients[serverID]?.capabilities = nil
        do {
            let raw = try await client.refreshCapabilities()
            let caps = SubsonicCapabilities.from(raw)
            let previous = try? await self.persistedCapabilities(serverID: serverID)
            self.clients[serverID]?.capabilities = caps
            try? await self.persistCapabilities(caps, serverID: serverID)
            if previous?.hasSameCapabilityFlags(as: caps) != true {
                self.capabilityContinuation.yield(serverID)
            }
            self.log.info(
                "subsonic.capabilities.refreshed",
                ["id": serverID.uuidString, "type": caps.serverType ?? "unknown"]
            )
            return caps
        } catch let e as SwiftSonicError {
            throw SubsonicError.transport(e)
        }
    }

    // MARK: - Browsing

    public func getArtists(serverID: UUID) async throws -> [ArtistIndex] {
        let client = try self.requireClient(serverID)
        do {
            return try await client.getArtists()
        } catch let e as SwiftSonicError {
            throw SubsonicError.transport(e)
        }
    }

    public func getArtist(serverID: UUID, id: String) async throws -> ArtistID3 {
        let client = try self.requireClient(serverID)
        do {
            return try await client.getArtist(id: id)
        } catch let e as SwiftSonicError {
            throw SubsonicError.transport(e)
        }
    }

    public func getAlbum(serverID: UUID, id: String) async throws -> AlbumID3 {
        let client = try self.requireClient(serverID)
        do {
            return try await client.getAlbum(id: id)
        } catch let e as SwiftSonicError {
            throw SubsonicError.transport(e)
        }
    }

    public func getGenres(serverID: UUID) async throws -> [Genre] {
        let client = try self.requireClient(serverID)
        do {
            return try await client.getGenres()
        } catch let e as SwiftSonicError {
            throw SubsonicError.transport(e)
        }
    }

    // MARK: - Lists

    public func getAlbumList2(
        serverID: UUID,
        type: AlbumListType,
        size: Int = 50,
        offset: Int = 0
    ) async throws -> [AlbumID3] {
        let client = try self.requireClient(serverID)
        do {
            return try await client.getAlbumList2(type: type, size: size, offset: offset)
        } catch let e as SwiftSonicError {
            throw SubsonicError.transport(e)
        }
    }

    public func getRandomSongs(serverID: UUID, size: Int = 50) async throws -> [Song] {
        let client = try self.requireClient(serverID)
        do {
            return try await client.getRandomSongs(size: size)
        } catch let e as SwiftSonicError {
            throw SubsonicError.transport(e)
        }
    }

    public func getSongsByGenre(
        serverID: UUID,
        genre: String,
        count: Int = 50,
        offset: Int = 0
    ) async throws -> [Song] {
        let client = try self.requireClient(serverID)
        do {
            return try await client.getSongsByGenre(genre, count: count, offset: offset)
        } catch let e as SwiftSonicError {
            throw SubsonicError.transport(e)
        }
    }

    public func getStarred2(serverID: UUID) async throws -> Starred2 {
        let client = try self.requireClient(serverID)
        do {
            return try await client.getStarred2()
        } catch let e as SwiftSonicError {
            throw SubsonicError.transport(e)
        }
    }

    // MARK: - Playlists

    public func getPlaylists(serverID: UUID) async throws -> [Playlist] {
        let client = try self.requireClient(serverID)
        do {
            return try await client.getPlaylists()
        } catch let e as SwiftSonicError {
            throw SubsonicError.transport(e)
        }
    }

    public func getPlaylist(serverID: UUID, id: String) async throws -> PlaylistWithSongs {
        let client = try self.requireClient(serverID)
        do {
            return try await client.getPlaylist(id: id)
        } catch let e as SwiftSonicError {
            throw SubsonicError.transport(e)
        }
    }

    // MARK: - Search

    public func search3(
        serverID: UUID,
        query: String,
        artistCount: Int = 5,
        albumCount: Int = 5,
        songCount: Int = 20
    ) async throws -> SearchResult3 {
        let client = try self.requireClient(serverID)
        do {
            return try await client.search3(
                query,
                artistCount: artistCount,
                albumCount: albumCount,
                songCount: songCount
            )
        } catch let e as SwiftSonicError {
            throw SubsonicError.transport(e)
        }
    }

    // MARK: - Podcasts (capability-gated)

    public func getPodcasts(serverID: UUID) async throws -> [PodcastChannel] {
        let client = try self.requireClient(serverID)
        do {
            return try await client.getPodcasts()
        } catch let e as SwiftSonicError {
            if isCapabilityLie(e) {
                await self.markCapabilityUnsupported("podcasts", for: serverID)
            }
            throw SubsonicError.transport(e)
        }
    }

    // MARK: - Internet radio (capability-gated)

    public func getInternetRadioStations(serverID: UUID) async throws -> [InternetRadioStation] {
        let client = try self.requireClient(serverID)
        do {
            return try await client.getInternetRadioStations()
        } catch let e as SwiftSonicError {
            if isCapabilityLie(e) {
                await self.markCapabilityUnsupported("internetRadio", for: serverID)
            }
            throw SubsonicError.transport(e)
        }
    }

    // MARK: - Bookmarks (capability-gated)

    public func getBookmarks(serverID: UUID) async throws -> [Bookmark] {
        let client = try self.requireClient(serverID)
        do {
            return try await client.getBookmarks()
        } catch let e as SwiftSonicError {
            if isCapabilityLie(e) {
                await self.markCapabilityUnsupported("bookmarks", for: serverID)
            }
            throw SubsonicError.transport(e)
        }
    }

    // MARK: - Now Playing

    public func getNowPlaying(serverID: UUID) async throws -> [NowPlayingEntry] {
        let client = try self.requireClient(serverID)
        do {
            return try await client.getNowPlaying()
        } catch let e as SwiftSonicError {
            throw SubsonicError.transport(e)
        }
    }

    // MARK: - Annotations

    public func star(serverID: UUID, songID: String) async throws {
        let client = try self.requireClient(serverID)
        do {
            try await client.star(songId: songID)
            self.log.debug("subsonic.star", ["server": serverID.uuidString, "song": songID])
        } catch let e as SwiftSonicError {
            throw SubsonicError.transport(e)
        }
    }

    public func unstar(serverID: UUID, songID: String) async throws {
        let client = try self.requireClient(serverID)
        do {
            try await client.unstar(songId: songID)
            self.log.debug("subsonic.unstar", ["server": serverID.uuidString, "song": songID])
        } catch let e as SwiftSonicError {
            throw SubsonicError.transport(e)
        }
    }

    public func setRating(serverID: UUID, songID: String, rating: Int) async throws {
        let client = try self.requireClient(serverID)
        do {
            try await client.setRating(id: songID, rating: rating)
            self.log.debug(
                "subsonic.rating",
                ["server": serverID.uuidString, "song": songID, "rating": rating]
            )
        } catch let e as SwiftSonicError {
            throw SubsonicError.transport(e)
        }
    }

    // MARK: - Scrobble

    public func scrobble(serverID: UUID, songID: String, submission: Bool = true) async throws {
        let client = try self.requireClient(serverID)
        do {
            try await client.scrobble(id: songID, submission: submission)
            self.log.debug(
                "subsonic.scrobble",
                ["server": serverID.uuidString, "song": songID, "submission": submission]
            )
        } catch let e as SwiftSonicError {
            throw SubsonicError.transport(e)
        }
    }

    // MARK: - Media URLs (nonisolated passthrough — never log these)

    /// Returns the stream URL for a song.
    ///
    /// > Warning: Never log this URL; it contains the per-request auth token.
    public func streamURL(
        serverID: UUID,
        songID: String,
        maxBitRate: Int? = nil,
        format: String? = nil
    ) throws -> URL {
        let client = try self.requireClient(serverID)
        guard let url = client.streamURL(id: songID, maxBitRate: maxBitRate, format: format) else {
            throw SubsonicError.invalidServerRecord("streamURL returned nil for song \(songID)")
        }
        return url
    }

    /// Returns the cover-art URL for an entity.
    public func coverArtURL(serverID: UUID, entityID: String, size: Int? = nil) throws -> URL? {
        let client = try self.requireClient(serverID)
        return client.coverArtURL(id: entityID, size: size)
    }

    // MARK: - Capability lie detection

    /// Marks a capability flag as `false` in the in-memory snapshot, persists
    /// the updated snapshot, and emits the server ID on `capabilityUpdates` so
    /// the sidebar drops the now-unsupported row.
    ///
    /// No-op when:
    /// - No capability snapshot has been loaded yet for `serverID`.
    /// - The flag is already `false` (idempotent).
    private func markCapabilityUnsupported(_ feature: String, for serverID: UUID) async {
        guard var caps = self.clients[serverID]?.capabilities else { return }
        let before = caps
        caps.markUnsupported(feature)
        guard !before.hasSameCapabilityFlags(as: caps) else { return }
        self.clients[serverID]?.capabilities = caps
        try? await self.persistCapabilities(caps, serverID: serverID)
        self.capabilityContinuation.yield(serverID)
        self.log.info(
            "subsonic.capability.revoked",
            ["id": serverID.uuidString, "feature": feature]
        )
    }

    // MARK: - Private helpers

    private func requireClient(_ serverID: UUID) throws -> SwiftSonicClient {
        guard let entry = self.clients[serverID] else {
            throw SubsonicError.unknownServer(serverID)
        }
        return entry.client
    }

    /// Reads the persisted capability snapshot for a server, or `nil` if none
    /// has been stored. Used to detect real capability changes before emitting
    /// on `capabilityUpdates`.
    private func persistedCapabilities(serverID: UUID) async throws -> SubsonicCapabilities? {
        guard let server = try await self.store.fetch(id: serverID),
              let data = server.cachedCapabilitiesJSON else { return nil }
        return try? JSONDecoder().decode(SubsonicCapabilities.self, from: data)
    }

    /// Persists a fresh capability snapshot to the store.
    private func persistCapabilities(_ caps: SubsonicCapabilities, serverID: UUID) async throws {
        let data = try JSONEncoder().encode(caps)
        try await self.store.updateCapabilities(serverID: serverID, capabilitiesJSON: data)
    }

    private func buildClient(for server: SubsonicServer) async throws {
        let secret = try await self.store.secret(for: server.id)

        let config: ServerConfiguration
        switch server.authKind {
        case .tokenSalt:
            guard let username = server.username else {
                throw SubsonicError.invalidServerRecord(
                    "tokenSalt auth requires a username for server \(server.id)"
                )
            }
            config = ServerConfiguration(
                serverURL: server.serverURL,
                auth: .tokenAuth(username: username, password: secret, reusesSalt: false),
                clientName: Self.clientName
            )
        case .apiKey:
            config = ServerConfiguration(
                serverURL: server.serverURL,
                auth: .apiKey(secret),
                clientName: Self.clientName
            )
        }

        let transport: (any HTTPTransport)? = if server.allowSelfSignedTLS, let host = server.serverURL.host {
            TrustBypassTransport(host: host)
        } else {
            nil
        }

        let metrics = SubsonicMetricsRelay(serverName: server.name)

        let client = if let transport {
            SwiftSonicClient(
                configuration: config,
                transport: transport,
                metricsCollector: metrics,
                logSubsystem: "io.cloudcauldron.bocan"
            )
        } else {
            SwiftSonicClient(
                configuration: config,
                metricsCollector: metrics,
                logSubsystem: "io.cloudcauldron.bocan"
            )
        }

        // Preserve any cached capabilities when refreshing an existing entry.
        let existing = self.clients[server.id]
        self.clients[server.id] = ClientEntry(
            client: client,
            capabilities: existing?.capabilities
        )
    }

    // MARK: - Test hooks

    /// Test-only seam: register a preconstructed `SwiftSonicClient` for a
    /// server without going through Keychain-backed `buildClient`. Production
    /// code must continue to use `reloadClients` / `refreshClient`.
    func _registerClientForTesting(_ client: SwiftSonicClient, serverID: UUID) {
        self.clients[serverID] = ClientEntry(client: client, capabilities: nil)
    }

    /// Test-only: read the in-memory capability snapshot without going through
    /// the staleness check. Production code should always use
    /// `loadCapabilities(serverID:)` instead.
    func _capabilitiesForTesting(serverID: UUID) -> SubsonicCapabilities? {
        self.clients[serverID]?.capabilities
    }
}

// MARK: - Private helpers (file-level)

/// Returns `true` when a `SwiftSonicError` signals the server does not
/// actually implement the requested endpoint despite advertising it in its
/// capability list.
///
/// Triggers:
/// - HTTP 404 — endpoint absent on the server
/// - HTTP 501 — server explicitly says "not implemented"
/// - Subsonic API error 70 (`.notFound`) — used by some servers for
///   optional endpoints they don't support
private func isCapabilityLie(_ error: SwiftSonicError) -> Bool {
    switch error {
    case let .httpError(statusCode, _, _):
        statusCode == 404 || statusCode == 501
    case let .api(apiError):
        apiError.code == .notFound
    default:
        false
    }
}
