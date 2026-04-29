import Foundation
import Observability

// MARK: - ListenBrainzConfig

public struct ListenBrainzConfig: Sendable, Equatable {
    public let endpoint: URL

    public init(endpoint: URL = URL(string: "https://api.listenbrainz.org")!) {
        self.endpoint = endpoint
    }
}

// MARK: - ListenBrainzCredentialsStore

public protocol ListenBrainzCredentialsStore: Sendable {
    func listenBrainzToken() async throws -> String?
    func setListenBrainz(token: String, username: String) async throws
    func clearListenBrainz() async throws
    func listenBrainzUsername() async throws -> String?
}

// MARK: - ListenBrainzProvider

/// `ScrobbleProvider` that talks to https://listenbrainz.org/ via its
/// `submit-listens` and `feedback` endpoints.
///
/// API docs: https://listenbrainz.readthedocs.io/en/latest/users/api/index.html
public actor ListenBrainzProvider: ScrobbleProvider {
    public nonisolated let id = "listenbrainz"
    public nonisolated let displayName = "ListenBrainz"

    private let config: ListenBrainzConfig
    private let http: HTTPClient
    private let credentials: any ListenBrainzCredentialsStore
    private let log = AppLogger.make(.scrobble)
    private let now: @Sendable () -> Date
    private var lastNowPlayingAt: Date?

    public init(
        config: ListenBrainzConfig = .init(),
        http: HTTPClient,
        credentials: any ListenBrainzCredentialsStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.http = http
        self.credentials = credentials
        self.now = now
    }

    public func isAuthenticated() async -> Bool {
        let token = try? await self.credentials.listenBrainzToken()
        return token?.isEmpty == false
    }

    public func nowPlaying(_ play: PlayEvent) async throws {
        let now = self.now()
        if let last = lastNowPlayingAt, now.timeIntervalSince(last) < 5 { return }
        self.lastNowPlayingAt = now

        guard let token = try await self.credentials.listenBrainzToken(), !token.isEmpty else {
            throw ScrobbleError.notAuthenticated(provider: self.id)
        }
        let payload = self.buildPayload(listenType: "playing_now", plays: [play])
        _ = try await self.post(path: "/1/submit-listens", token: token, payload: payload)
        self.log.debug("scrobble.listenbrainz.nowplaying.ok", ["title": play.title])
    }

    public func submit(_ plays: [PlayEvent]) async throws -> [SubmissionResult] {
        guard !plays.isEmpty else { return [] }
        guard let token = try await self.credentials.listenBrainzToken(), !token.isEmpty else {
            throw ScrobbleError.notAuthenticated(provider: self.id)
        }

        // The API accepts up to ~1000 listens per call but we mirror the
        // worker's batch-of-50 semantic for parity with Last.fm.
        let batches = stride(from: 0, to: plays.count, by: 50).map {
            Array(plays[$0 ..< min($0 + 50, plays.count)])
        }
        var out: [SubmissionResult] = []
        out.reserveCapacity(plays.count)
        for batch in batches {
            let payload = self.buildPayload(listenType: batch.count == 1 ? "single" : "import", plays: batch)
            do {
                _ = try await self.post(path: "/1/submit-listens", token: token, payload: payload)
                out.append(contentsOf: batch.map { SubmissionResult(queueID: $0.queueID, outcome: .success) })
                self.log.info("scrobble.listenbrainz.batch.ok", ["count": batch.count])
            } catch let ScrobbleError.transient(_, reason, retryAfter) {
                out.append(contentsOf: batch.map {
                    SubmissionResult(queueID: $0.queueID, outcome: .retry(reason: reason, after: retryAfter))
                })
            } catch let ScrobbleError.permanent(_, reason) {
                out.append(contentsOf: batch.map {
                    SubmissionResult(queueID: $0.queueID, outcome: .permanentFailure(reason: reason))
                })
            }
        }
        return out
    }

    public func love(track: TrackIdentity, loved: Bool) async throws {
        guard let token = try await self.credentials.listenBrainzToken(), !token.isEmpty else {
            throw ScrobbleError.notAuthenticated(provider: self.id)
        }
        // ListenBrainz "feedback" endpoint maps to recording_mbid + score (1/0/-1).
        // Without an MBID we cannot send feedback, so silently skip.
        guard let mbid = track.mbid, !mbid.isEmpty else {
            self.log.debug("scrobble.listenbrainz.love.skip", ["reason": "no mbid"])
            return
        }
        let payload: [String: Any] = [
            "recording_mbid": mbid,
            "score": loved ? 1 : 0,
        ]
        _ = try await self.post(path: "/1/feedback/recording-feedback", token: token, payload: payload)
        self.log.info("scrobble.listenbrainz.love", ["loved": loved])
    }

    /// Validate a token via `/1/validate-token`. Used by the connect flow.
    public func validate(token: String) async throws -> String {
        var components = URLComponents(url: self.config.endpoint, resolvingAgainstBaseURL: true)!
        components.path = "/1/validate-token"
        var req = URLRequest(url: components.url!)
        req.httpMethod = "GET"
        req.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await self.http.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 200 {
            let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let parsed, let valid = parsed["valid"] as? Bool, valid,
               let user = parsed["user_name"] as? String, !user.isEmpty {
                return user
            }
            throw ScrobbleError.invalidCredentials(provider: self.id)
        }
        if status == 401 || status == 403 { throw ScrobbleError.invalidCredentials(provider: self.id) }
        if status >= 500 { throw ScrobbleError.transient(provider: self.id, reason: "http \(status)", retryAfter: nil) }
        throw ScrobbleError.permanent(provider: self.id, reason: "http \(status)")
    }

    // MARK: Private

    private func buildPayload(listenType: String, plays: [PlayEvent]) -> [String: Any] {
        let listens = plays.map { play -> [String: Any] in
            var trackMetadata: [String: Any] = [
                "artist_name": play.artist,
                "track_name": play.title,
            ]
            if let album = play.album { trackMetadata["release_name"] = album }
            var additional: [String: Any] = [:]
            additional["media_player"] = "Bòcan"
            additional["submission_client"] = "Bòcan"
            if let mbid = play.mbid { additional["recording_mbid"] = mbid }
            if play.duration > 0 { additional["duration_ms"] = Int(play.duration * 1000) }
            if !additional.isEmpty {
                trackMetadata["additional_info"] = additional
            }
            var listen: [String: Any] = ["track_metadata": trackMetadata]
            if listenType != "playing_now" {
                listen["listened_at"] = Int(play.playedAt.timeIntervalSince1970)
            }
            return listen
        }
        return [
            "listen_type": listenType,
            "payload": listens,
        ]
    }

    @discardableResult
    private func post(path: String, token: String, payload: [String: Any]) async throws -> [String: Any] {
        var components = URLComponents(url: self.config.endpoint, resolvingAgainstBaseURL: true)!
        components.path = path
        guard let url = components.url else {
            throw ScrobbleError.malformedResponse(provider: self.id, reason: "bad url")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])

        let (data, response) = try await self.http.data(for: req)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)

        if status >= 200, status < 300 {
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
        switch status {
        case 401, 403:
            throw ScrobbleError.invalidCredentials(provider: self.id)
        case 429:
            throw ScrobbleError.transient(provider: self.id, reason: "rate limited", retryAfter: retryAfter ?? 60)
        case 500 ... 599:
            throw ScrobbleError.transient(provider: self.id, reason: "http \(status)", retryAfter: retryAfter)
        default:
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw ScrobbleError.permanent(provider: self.id, reason: "http \(status): \(body.prefix(200))")
        }
    }
}
