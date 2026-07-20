import Foundation
import Observability

// MARK: - RockskyConfig

/// Endpoint configuration for the Rocksky scrobble service.
///
/// Rocksky exposes a ListenBrainz-compatible API at `audioscrobbler.rocksky.app`.
/// Authentication is via the user's API key sent as a Bearer token — no
/// shared secret or signed requests are required.
public struct RockskyConfig: Sendable, Equatable {
    public let endpoint: URL

    public init(endpoint: URL = URL(string: "https://audioscrobbler.rocksky.app")!) {
        self.endpoint = endpoint
    }
}

// MARK: - RockskyProvider

/// `ScrobbleProvider` for https://rocksky.app/.
///
/// Uses Rocksky's ListenBrainz-compatible API — the same JSON protocol used
/// by Jellyfin, Navidrome, and Pano Scrobbler. The user's Rocksky API key
/// (from rocksky.app/apikeys) is sent as a Bearer token. No shared secret
/// or signed requests are required.
public actor RockskyProvider: ScrobbleProvider {
    public nonisolated let id = "rocksky"
    public nonisolated let displayName = "Rocksky"

    private let config: RockskyConfig
    private let transport: ListenBrainzCompatibleTransport
    private let credentials: any RockskyCredentialsStore
    private let log = AppLogger.make(.scrobble)
    private let now: @Sendable () -> Date
    private var lastNowPlayingAt: Date?

    public init(
        config: RockskyConfig = .init(),
        http: HTTPClient,
        credentials: any RockskyCredentialsStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.transport = ListenBrainzCompatibleTransport(http: http, endpoint: config.endpoint)
        self.credentials = credentials
        self.now = now
    }

    // MARK: ScrobbleProvider

    public func isAuthenticated() async -> Bool {
        let key = try? await self.credentials.rockskyApiKey()
        return key?.isEmpty == false
    }

    public func nowPlaying(_ play: PlayEvent) async throws {
        let now = self.now()
        if let last = lastNowPlayingAt, now.timeIntervalSince(last) < 5 { return }
        self.lastNowPlayingAt = now

        guard let token = try await self.credentials.rockskyApiKey(), !token.isEmpty else {
            throw ScrobbleError.notAuthenticated(provider: self.id)
        }
        let payload = self.transport.buildPayload(listenType: "playing_now", plays: [play])
        _ = try await self.transport.post(path: "/1/submit-listens", token: token, payload: payload, providerID: self.id)
        self.log.debug("scrobble.rocksky.nowplaying.ok", ["title": play.title])
    }

    public func submit(_ plays: [PlayEvent]) async throws -> [SubmissionResult] {
        guard !plays.isEmpty else { return [] }
        guard let token = try await self.credentials.rockskyApiKey(), !token.isEmpty else {
            throw ScrobbleError.notAuthenticated(provider: self.id)
        }

        let batches = stride(from: 0, to: plays.count, by: 50).map {
            Array(plays[$0 ..< min($0 + 50, plays.count)])
        }
        var out: [SubmissionResult] = []
        out.reserveCapacity(plays.count)
        for batch in batches {
            let payload = self.transport.buildPayload(listenType: batch.count == 1 ? "single" : "import", plays: batch)
            do {
                _ = try await self.transport.post(path: "/1/submit-listens", token: token, payload: payload, providerID: self.id)
                out.append(contentsOf: batch.map { SubmissionResult(queueID: $0.queueID, outcome: .success) })
                self.log.info("scrobble.rocksky.batch.ok", ["count": batch.count])
            } catch let ScrobbleError.transient(_, reason, retryAfter) {
                self.log.warning("scrobble.rocksky.batch.transient", ["reason": reason])
                out.append(contentsOf: batch.map {
                    SubmissionResult(queueID: $0.queueID, outcome: .retry(reason: reason, after: retryAfter))
                })
            } catch let ScrobbleError.permanent(_, reason) {
                self.log.error("scrobble.rocksky.batch.permanent", ["reason": reason])
                out.append(contentsOf: batch.map {
                    SubmissionResult(queueID: $0.queueID, outcome: .permanentFailure(reason: reason))
                })
            }
        }
        return out
    }

    public func love(track: TrackIdentity, loved: Bool) async throws {
        // Rocksky's ListenBrainz-compatible scrobble API does not expose a
        // feedback/love endpoint. Loved state is managed via their native
        // XRPC API (api.rocksky.app), which requires a separate integration.
        // Skip silently so callers don't surface a spurious error.
        self.log.debug("scrobble.rocksky.love.skip", ["reason": "not supported by scrobble api", "track": track.title])
    }
}

// MARK: - RockskyCredentialsStore

/// Narrow credentials protocol for `RockskyProvider`.
/// Keeps the provider testable with in-memory stubs.
public protocol RockskyCredentialsStore: Sendable {
    func rockskyApiKey() async throws -> String?
    func setRocksky(apiKey: String) async throws
    func clearRocksky() async throws
}
