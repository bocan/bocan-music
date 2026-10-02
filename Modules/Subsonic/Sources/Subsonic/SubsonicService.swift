import Foundation
import Observability
import SwiftSonic

// The metrics relay and the self-signed-TLS transport that `buildClient` gives
// each client are in `SubsonicServiceTransport.swift`. The endpoint methods are
// in `SubsonicService+Endpoints.swift`.

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
    let log = AppLogger.make(.subsonic)
    private var (capabilityStream, capabilityContinuation) = AsyncStream<UUID>.makeStream()

    // MARK: - Init

    /// Creates a service with an empty client pool. Until `reloadClients()` or
    /// `refreshClient(for:)` adds a client, requests throw `SubsonicError.unknownServer`.
    public init(store: SubsonicServerStore) {
        self.store = store
    }

    /// Broadcasts server IDs whose advertised capabilities have changed since
    /// the previously persisted snapshot. The UI subscribes here to redraw
    /// the sidebar when a server upgrade unlocks new sections (ADR-035 step
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
        let liveIDs = Set(servers.map(\.id))
        // Drop clients for servers that no longer exist, but keep the rest so a
        // transient credential-read failure on one server cannot take down the
        // healthy ones (previously `self.clients = [:]` wiped the whole pool).
        self.clients = self.clients.filter { liveIDs.contains($0.key) }

        var built = 0
        for server in servers {
            do {
                try await self.buildClient(for: server)
                built += 1
            } catch {
                // Preserve any prior client for this server; a later refresh
                // (e.g. Settings "Test") or the next reload can recover it.
                self.log.error(
                    "subsonic.service.client.buildFailed",
                    ["id": server.id.uuidString, "error": String(reflecting: error)]
                )
            }
        }
        self.log.info("subsonic.service.reloaded", ["count": servers.count, "built": built])
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
        try await self.withClient(serverID) { client in
            try await client.ping()
            self.log.debug("subsonic.ping.ok", ["id": serverID.uuidString])
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
            let advertised = SubsonicCapabilities.from(raw)
            let caps = await self.probeLegacyCoreCapabilities(advertised, serverID: serverID)
            let previous: SubsonicCapabilities?
            do { previous = try await self.persistedCapabilities(serverID: serverID) } catch {
                self.log.warning("subsonic.capabilities.persist.read.failed", ["error": String(reflecting: error)])
                previous = nil
            }
            self.clients[serverID]?.capabilities = caps
            do {
                try await self.persistCapabilities(caps, serverID: serverID)
            } catch {
                self.log.warning("subsonic.capabilities.persist.write.failed", ["error": String(reflecting: error)])
            }
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
        } catch let sonicError as SwiftSonicError {
            throw SubsonicError.transport(sonicError)
        }
    }

    /// Forces a fresh capability fetch, bypassing the staleness check.
    /// Also bypasses the SwiftSonic client's own capability cache so a real
    /// network refetch happens — required for capability-change detection
    /// after a server upgrade (ADR-035 step 16).
    public func refreshCapabilities(serverID: UUID) async throws -> SubsonicCapabilities {
        let client = try self.requireClient(serverID)
        self.clients[serverID]?.capabilities = nil
        do {
            let raw = try await client.refreshCapabilities()
            let advertised = SubsonicCapabilities.from(raw)
            let caps = await self.probeLegacyCoreCapabilities(advertised, serverID: serverID)
            let previous: SubsonicCapabilities?
            do { previous = try await self.persistedCapabilities(serverID: serverID) } catch {
                self.log.warning("subsonic.capabilities.persist.read.failed", ["error": String(reflecting: error)])
                previous = nil
            }
            self.clients[serverID]?.capabilities = caps
            do {
                try await self.persistCapabilities(caps, serverID: serverID)
            } catch {
                self.log.warning("subsonic.capabilities.persist.write.failed", ["error": String(reflecting: error)])
            }
            if previous?.hasSameCapabilityFlags(as: caps) != true {
                self.capabilityContinuation.yield(serverID)
            }
            self.log.info(
                "subsonic.capabilities.refreshed",
                ["id": serverID.uuidString, "type": caps.serverType ?? "unknown"]
            )
            return caps
        } catch let sonicError as SwiftSonicError {
            throw SubsonicError.transport(sonicError)
        }
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
        do {
            try await self.persistCapabilities(caps, serverID: serverID)
        } catch {
            self.log.warning("subsonic.capabilities.persist.write.failed", ["error": String(reflecting: error)])
        }
        self.capabilityContinuation.yield(serverID)
        self.log.info(
            "subsonic.capability.revoked",
            ["id": serverID.uuidString, "feature": feature]
        )
    }

    // MARK: - Private helpers

    /// Internal-only accessor used by the legacy-core capability probe in
    /// `SubsonicService+CapabilityProbe.swift`.
    func clientForCapabilityProbe(serverID: UUID) -> SwiftSonicClient? {
        self.clients[serverID]?.client
    }

    func requireClient(_ serverID: UUID) throws -> SwiftSonicClient {
        guard let entry = self.clients[serverID] else {
            throw SubsonicError.unknownServer(serverID)
        }
        return entry.client
    }

    /// Resolves the client for `serverID`, runs `body` against it, and maps any
    /// `SwiftSonicError` to `SubsonicError.transport`. Folds the request wrapper
    /// that every endpoint method otherwise repeats verbatim.
    func withClient<T>(
        _ serverID: UUID,
        _ body: (SwiftSonicClient) async throws -> T
    ) async throws -> T {
        let client = try self.requireClient(serverID)
        do {
            return try await body(client)
        } catch let sonicError as SwiftSonicError {
            throw SubsonicError.transport(sonicError)
        }
    }

    /// Like `withClient`, but for capability-gated endpoints: when the server
    /// 404/501s an endpoint it advertised, `feature`'s capability flag is
    /// revoked before the error is surfaced (see `isCapabilityLie`).
    func withCapabilityGatedClient<T>(
        _ serverID: UUID,
        feature: String,
        _ body: (SwiftSonicClient) async throws -> T
    ) async throws -> T {
        let client = try self.requireClient(serverID)
        do {
            return try await body(client)
        } catch let sonicError as SwiftSonicError {
            if isCapabilityLie(sonicError) {
                await self.markCapabilityUnsupported(feature, for: serverID)
            }
            throw SubsonicError.transport(sonicError)
        }
    }

    /// Whether this server mirrors the stars the user sets (`syncStars`).
    ///
    /// A server whose record cannot be read answers `false`: an annotation is
    /// never sent to a server whose settings are unknown, and the reason
    /// reaches the log rather than the user (#502).
    public func syncsStars(serverID: UUID) async -> Bool {
        await self.serverFlag(serverID: serverID, flag: \.syncStars, name: "syncStars")
    }

    /// Whether this server mirrors the ratings the user sets (`syncRatings`).
    /// Same read-failure contract as `syncsStars`.
    public func syncsRatings(serverID: UUID) async -> Bool {
        await self.serverFlag(serverID: serverID, flag: \.syncRatings, name: "syncRatings")
    }

    private func serverFlag(
        serverID: UUID,
        flag: KeyPath<SubsonicServer, Bool>,
        name: String
    ) async -> Bool {
        do {
            guard let server = try await self.store.fetch(id: serverID) else {
                self.log.warning("subsonic.serverFlag.missing", ["server": serverID.uuidString, "flag": name])
                return false
            }
            return server[keyPath: flag]
        } catch {
            self.log.warning(
                "subsonic.serverFlag.readFailed",
                ["server": serverID.uuidString, "flag": name, "error": String(reflecting: error)]
            )
            return false
        }
    }

    /// Reads the persisted capability snapshot for a server, or `nil` if none
    /// has been stored. Used to detect real capability changes before emitting
    /// on `capabilityUpdates`.
    private func persistedCapabilities(serverID: UUID) async throws -> SubsonicCapabilities? {
        guard let server = try await self.store.fetch(id: serverID),
              let data = server.cachedCapabilitiesJSON else { return nil }
        do {
            return try JSONDecoder().decode(SubsonicCapabilities.self, from: data)
        } catch {
            self.log.warning("subsonic.capabilities.decode.failed", ["server": serverID.uuidString, "error": String(reflecting: error)])
            return nil
        }
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
    func registerClientForTesting(_ client: SwiftSonicClient, serverID: UUID) {
        self.clients[serverID] = ClientEntry(client: client, capabilities: nil)
    }

    /// Test-only: read the in-memory capability snapshot without going through
    /// the staleness check. Production code should always use
    /// `loadCapabilities(serverID:)` instead.
    func capabilitiesForTesting(serverID: UUID) -> SubsonicCapabilities? {
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
func isCapabilityLie(_ error: SwiftSonicError) -> Bool {
    switch error {
    case let .httpError(statusCode, _, _):
        statusCode == 404 || statusCode == 501

    case let .api(apiError):
        apiError.code == .notFound

    default:
        false
    }
}
