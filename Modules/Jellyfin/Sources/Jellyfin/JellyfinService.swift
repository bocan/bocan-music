import Foundation
import Observability

// The endpoint methods are in `JellyfinService+Endpoints.swift`.

// MARK: - JellyfinService

/// Central actor owning a pool of clients, one per configured Jellyfin server.
/// It mirrors `SubsonicService`.
///
/// ## Security
/// Stream and image URLs carry the access token as `ApiKey`. **Never log
/// these URLs**, never put one in an error, never store one. The log
/// redaction scrubs the parameter as a second line of defence only.
public actor JellyfinService {
    /// The ASCII app name sent in the client header, shown on the server's
    /// Devices page. Mirrors Subsonic's `c` value.
    static let clientName = "Bocan"

    /// Builds a client for a server. The default builds the SDK client; tests pass a stub.
    typealias ClientFactory = @Sendable (JellyfinClientConfiguration) -> any JellyfinClientProtocol

    // MARK: - State

    private var clients: [UUID: any JellyfinClientProtocol] = [:]
    private let store: JellyfinServerStore
    private let identity: JellyfinClientIdentity
    private let makeClient: ClientFactory
    let log = AppLogger.make(.jellyfin)

    // MARK: - Init

    /// Creates a service with an empty client pool. Until `reloadClients()` or
    /// `refreshClient(for:)` adds a client, requests throw `JellyfinError.unknownServer`.
    public init(store: JellyfinServerStore) {
        self.init(store: store, identity: .current()) { JellyfinSDKClient(configuration: $0) }
    }

    init(store: JellyfinServerStore, identity: JellyfinClientIdentity, makeClient: @escaping ClientFactory) {
        self.store = store
        self.identity = identity
        self.makeClient = makeClient
    }

    // MARK: - Client pool management

    /// Rebuilds the client pool from the current server list.
    /// Call once on app start, and again whenever a server is added, edited or removed.
    public func reloadClients() async throws {
        let servers = try await self.store.fetchAll()
        let liveIDs = Set(servers.map(\.id))
        // Drop clients for servers that no longer exist, but keep the rest so a
        // transient Keychain failure on one server cannot take down the healthy ones.
        self.clients = self.clients.filter { liveIDs.contains($0.key) }

        var built = 0
        for server in servers {
            do {
                try await self.buildClient(for: server)
                built += 1
            } catch {
                // Keep any prior client for this server; a later refresh can recover it.
                self.log.error(
                    "jellyfin.service.client.buildFailed",
                    ["id": server.id.uuidString, "error": String(reflecting: error)]
                )
            }
        }
        self.log.info("jellyfin.service.reloaded", ["count": servers.count, "built": built])
    }

    /// Inserts or replaces the client for a single server.
    /// Use after `JellyfinServerStore.add` or `JellyfinServerStore.update`.
    public func refreshClient(for server: JellyfinServer) async throws {
        try await self.buildClient(for: server)
        self.log.debug("jellyfin.service.client.refresh", ["id": server.id.uuidString])
    }

    /// Removes the client for a deleted server.
    public func removeClient(for serverID: UUID) {
        self.clients.removeValue(forKey: serverID)
        self.log.debug("jellyfin.service.client.remove", ["id": serverID.uuidString])
    }

    /// Removes a server for good: asks it to end this device's token first (best
    /// effort), then deletes the row, the Keychain item and the cached metadata,
    /// and drops the client. A server that cannot be reached never blocks the removal.
    public func removeServer(id: UUID) async throws {
        await self.endSession(serverID: id)
        try await self.store.remove(id: id)
        self.removeClient(for: id)
    }

    // MARK: - System

    /// Makes an authenticated round trip; throws `JellyfinError` on failure.
    /// A revoked token throws `.unauthorized`.
    public func ping(serverID: UUID) async throws {
        try await self.withClient(serverID) { try await $0.ping() }
        self.log.debug("jellyfin.ping.ok", ["id": serverID.uuidString])
    }

    /// The server's name and version, as "Test server" shows them.
    public func serverInfo(serverID: UUID) async throws -> JellyfinServerInfo {
        try await self.withClient(serverID) { try await $0.serverInfo() }
    }

    /// Stores the time of the last successful ping. A failure is logged, never thrown:
    /// a status dot must not break because a timestamp could not be saved.
    func recordConnected(serverID: UUID, at date: Date) async {
        do {
            try await self.store.updateLastConnected(serverID: serverID, at: date)
        } catch {
            self.log.warning(
                "jellyfin.connected.persist.failed",
                ["id": serverID.uuidString, "error": String(reflecting: error)]
            )
        }
    }

    // MARK: - Flags

    /// Whether this server mirrors the stars the user sets (`syncStars`).
    ///
    /// A server whose record cannot be read answers `false`: an annotation is
    /// never sent to a server whose settings are unknown, and the reason
    /// reaches the log rather than the user (#502).
    public func syncsStars(serverID: UUID) async -> Bool {
        await self.serverFlag(serverID: serverID, flag: \.syncStars, name: "syncStars")
    }

    /// Whether this server wants play reports (`scrobble`). Same read-failure contract.
    public func reportsPlays(serverID: UUID) async -> Bool {
        await self.serverFlag(serverID: serverID, flag: \.scrobble, name: "scrobble")
    }

    private func serverFlag(
        serverID: UUID,
        flag: KeyPath<JellyfinServer, Bool>,
        name: String
    ) async -> Bool {
        do {
            guard let server = try await self.store.fetch(id: serverID) else {
                self.log.warning("jellyfin.serverFlag.missing", ["server": serverID.uuidString, "flag": name])
                return false
            }
            return server[keyPath: flag]
        } catch {
            self.log.warning(
                "jellyfin.serverFlag.readFailed",
                ["server": serverID.uuidString, "flag": name, "error": String(reflecting: error)]
            )
            return false
        }
    }

    // MARK: - Internals

    func requireClient(_ serverID: UUID) throws -> any JellyfinClientProtocol {
        guard let client = self.clients[serverID] else {
            throw JellyfinError.unknownServer(serverID)
        }
        return client
    }

    /// Resolves the client for `serverID` and runs `body` against it.
    func withClient<T>(
        _ serverID: UUID,
        _ body: (any JellyfinClientProtocol) async throws -> T
    ) async throws -> T {
        try await body(self.requireClient(serverID))
    }

    private func buildClient(for server: JellyfinServer) async throws {
        let token = try await self.store.accessToken(for: server.id)
        let configuration = JellyfinClientConfiguration(
            serverURL: server.serverURL,
            deviceID: server.deviceID,
            identity: self.identity,
            allowSelfSignedTLS: server.allowSelfSignedTLS,
            userID: server.userID,
            accessToken: token
        )
        self.clients[server.id] = self.makeClient(configuration)
    }

    // MARK: - Test hooks

    /// Test-only seam: register a preconstructed client without going through
    /// the Keychain-backed `buildClient`. Production code uses `reloadClients`
    /// and `refreshClient`.
    func registerClientForTesting(_ client: any JellyfinClientProtocol, serverID: UUID) {
        self.clients[serverID] = client
    }
}
