import Foundation
import Observability

// MARK: - LastFmConfig

/// Per-build constants for Last.fm.
///
/// The API key + shared secret are *not* secrets in the cryptographic sense —
/// every desktop client ships them in plain text. They are still build-time
/// rather than source-checked-in to make rotation easier; a missing key
/// disables the provider rather than crashing.
public struct LastFmConfig: Sendable, Equatable {
    public let apiKey: String
    public let sharedSecret: String
    public let endpoint: URL
    public let authPageBase: URL

    public init(
        apiKey: String,
        sharedSecret: String,
        endpoint: URL = URL(string: "https://ws.audioscrobbler.com/2.0/")!,
        authPageBase: URL = URL(string: "https://www.last.fm/api/auth/")!
    ) {
        self.apiKey = apiKey
        self.sharedSecret = sharedSecret
        self.endpoint = endpoint
        self.authPageBase = authPageBase
    }

    /// `true` if both the API key and shared secret are non-empty.
    public var isConfigured: Bool {
        !self.apiKey.isEmpty && !self.sharedSecret.isEmpty
    }

    /// Production config built from `Info.plist` build constants. Returns
    /// `nil` if the keys are missing — the app should hide the Last.fm UI.
    public static func fromBundle(_ bundle: Bundle = .main) -> LastFmConfig? {
        guard
            let apiKey = bundle.object(forInfoDictionaryKey: "BocanLastFmApiKey") as? String,
            let secret = bundle.object(forInfoDictionaryKey: "BocanLastFmSharedSecret") as? String,
            !apiKey.isEmpty, !secret.isEmpty else { return nil }
        return LastFmConfig(apiKey: apiKey, sharedSecret: secret)
    }
}

// MARK: - LastFmProvider

/// `ScrobbleProvider` that talks to Last.fm's web service 2.0.
///
/// Thread-safety: `actor`. Authentication state (the session key) is read on
/// demand from the injected `Credentials` store; the provider itself is stateless.
public actor LastFmProvider: ScrobbleProvider {
    public nonisolated let id = "lastfm"
    public nonisolated let displayName = "Last.fm"

    /// Last "now playing" submission timestamp; we throttle to once per 5 s
    /// so a fast-skipping user doesn't spam the service.
    private var lastNowPlayingAt: Date?

    private let config: LastFmConfig
    private let http: HTTPClient
    private let credentials: any LastFmCredentialsStore
    private let log = AppLogger.make(.scrobble)
    private let now: @Sendable () -> Date

    public init(
        config: LastFmConfig,
        http: HTTPClient,
        credentials: any LastFmCredentialsStore,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.http = http
        self.credentials = credentials
        self.now = now
    }

    // MARK: ScrobbleProvider

    public func isAuthenticated() async -> Bool {
        let key = try? await self.credentials.lastFmSessionKey()
        return key?.isEmpty == false
    }

    public func nowPlaying(_ play: PlayEvent) async throws {
        let now = self.now()
        if let last = lastNowPlayingAt, now.timeIntervalSince(last) < 5 { return }
        self.lastNowPlayingAt = now

        guard self.config.isConfigured else { throw ScrobbleError.notAuthenticated(provider: self.id) }
        guard let session = try await credentials.lastFmSessionKey(), !session.isEmpty else {
            throw ScrobbleError.notAuthenticated(provider: self.id)
        }

        var params: [String: String] = [
            "method": "track.updateNowPlaying",
            "api_key": self.config.apiKey,
            "sk": session,
            "artist": play.artist,
            "track": play.title,
            "duration": String(Int(play.duration.rounded())),
        ]
        if let album = play.album { params["album"] = album }
        if let albumArtist = play.albumArtist { params["albumArtist"] = albumArtist }
        if let mbid = play.mbid { params["mbid"] = mbid }

        _ = try await self.signedPost(params)
        self.log.debug("scrobble.lastfm.nowplaying.ok", ["title": play.title])
    }

    public func submit(_ plays: [PlayEvent]) async throws -> [SubmissionResult] {
        guard !plays.isEmpty else { return [] }
        guard self.config.isConfigured else {
            return plays.map { SubmissionResult(queueID: $0.queueID, outcome: .permanentFailure(reason: "lastfm not configured")) }
        }
        guard let session = try await credentials.lastFmSessionKey(), !session.isEmpty else {
            throw ScrobbleError.notAuthenticated(provider: self.id)
        }

        // Last.fm accepts up to 50 in a batch.
        let batches = stride(from: 0, to: plays.count, by: 50).map {
            Array(plays[$0 ..< min($0 + 50, plays.count)])
        }

        var allResults: [SubmissionResult] = []
        allResults.reserveCapacity(plays.count)
        for batch in batches {
            var params: [String: String] = [
                "method": "track.scrobble",
                "api_key": self.config.apiKey,
                "sk": session,
            ]
            for (i, play) in batch.enumerated() {
                params["artist[\(i)]"] = play.artist
                params["track[\(i)]"] = play.title
                params["timestamp[\(i)]"] = String(Int(play.playedAt.timeIntervalSince1970))
                if let album = play.album { params["album[\(i)]"] = album }
                if let albumArtist = play.albumArtist { params["albumArtist[\(i)]"] = albumArtist }
                if let mbid = play.mbid { params["mbid[\(i)]"] = mbid }
                params["duration[\(i)]"] = String(Int(play.duration.rounded()))
            }

            do {
                _ = try await self.signedPost(params)
                allResults.append(contentsOf: batch.map { SubmissionResult(queueID: $0.queueID, outcome: .success) })
                self.log.info("scrobble.lastfm.batch.ok", ["count": batch.count])
            } catch let ScrobbleError.transient(_, reason, retryAfter) {
                self.log.warning("scrobble.lastfm.batch.transient", ["reason": reason])
                allResults.append(contentsOf: batch.map {
                    SubmissionResult(queueID: $0.queueID, outcome: .retry(reason: reason, after: retryAfter))
                })
            } catch let ScrobbleError.permanent(_, reason) {
                self.log.error("scrobble.lastfm.batch.permanent", ["reason": reason])
                allResults.append(contentsOf: batch.map {
                    SubmissionResult(queueID: $0.queueID, outcome: .permanentFailure(reason: reason))
                })
            }
        }
        return allResults
    }

    public func love(track: TrackIdentity, loved: Bool) async throws {
        guard self.config.isConfigured else { throw ScrobbleError.notAuthenticated(provider: self.id) }
        guard let session = try await credentials.lastFmSessionKey(), !session.isEmpty else {
            throw ScrobbleError.notAuthenticated(provider: self.id)
        }
        var params: [String: String] = [
            "method": loved ? "track.love" : "track.unlove",
            "api_key": self.config.apiKey,
            "sk": session,
            "artist": track.artist,
            "track": track.title,
        ]
        if let mbid = track.mbid { params["mbid"] = mbid }
        _ = try await self.signedPost(params)
        self.log.info("scrobble.lastfm.love", ["loved": loved, "track": track.title])
    }

    // MARK: Auth helpers (called by LastFmAuth)

    /// `auth.getToken` — returns a temporary token for the desktop auth flow.
    public func requestAuthToken() async throws -> String {
        guard self.config.isConfigured else { throw ScrobbleError.notAuthenticated(provider: self.id) }
        let params: [String: String] = [
            "method": "auth.getToken",
            "api_key": self.config.apiKey,
        ]
        let json = try await self.signedGet(params)
        guard let token = json["token"] as? String, !token.isEmpty else {
            throw ScrobbleError.malformedResponse(provider: self.id, reason: "missing token")
        }
        return token
    }

    /// `auth.getSession` — exchanges an authorised token for a permanent session key.
    public func requestSession(token: String) async throws -> (sessionKey: String, username: String) {
        guard self.config.isConfigured else { throw ScrobbleError.notAuthenticated(provider: self.id) }
        let params: [String: String] = [
            "method": "auth.getSession",
            "api_key": self.config.apiKey,
            "token": token,
        ]
        let json = try await self.signedGet(params)
        // `send` strips a single outer envelope, so the `session` wrapper is gone.
        guard
            let key = json["key"] as? String,
            let user = json["name"] as? String,
            !key.isEmpty else {
            throw ScrobbleError.malformedResponse(provider: self.id, reason: "missing session")
        }
        return (key, user)
    }

    /// Browser URL the user needs to open to authorise the token.
    public nonisolated func authorisationURL(forToken token: String) -> URL {
        var components = URLComponents(url: self.config.authPageBase, resolvingAgainstBaseURL: true)
            ?? URLComponents(string: self.config.authPageBase.absoluteString)!
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "api_key", value: self.config.apiKey))
        items.append(URLQueryItem(name: "token", value: token))
        components.queryItems = items
        return components.url ?? self.config.authPageBase
    }

    // MARK: HTTP

    private func signedPost(_ params: [String: String]) async throws -> [String: Any] {
        try await self.send(params: params, method: "POST")
    }

    private func signedGet(_ params: [String: String]) async throws -> [String: Any] {
        try await self.send(params: params, method: "GET")
    }

    private func send(params: [String: String], method: String) async throws -> [String: Any] {
        var p = params
        p["api_sig"] = LastFmSignature.sign(p, secret: self.config.sharedSecret)
        p["format"] = "json"

        let request = try self.makeRequest(params: p, method: method)
        let (data, response) = try await self.http.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)

        if status >= 500 {
            throw ScrobbleError.transient(provider: self.id, reason: "http \(status)", retryAfter: retryAfter)
        }

        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw ScrobbleError.malformedResponse(provider: self.id, reason: "invalid json")
        }
        guard var json = parsed as? [String: Any] else {
            throw ScrobbleError.malformedResponse(provider: self.id, reason: "not an object")
        }

        if let errCode = json["error"] as? Int {
            let msg = (json["message"] as? String) ?? "error \(errCode)"
            // Codes per https://www.last.fm/api/errorcodes
            switch errCode {
            case 11, 16: // Service offline / Service temporarily unavailable
                throw ScrobbleError.transient(provider: self.id, reason: msg, retryAfter: retryAfter)
            case 29: // Rate limit exceeded
                throw ScrobbleError.transient(provider: self.id, reason: msg, retryAfter: retryAfter ?? 60)
            case 9: // Invalid session key — re-auth required
                throw ScrobbleError.invalidCredentials(provider: self.id)
            case 4, 13, 14, 17, 18, 22, 23: // Auth failed / token invalid / unauthorised
                throw ScrobbleError.invalidCredentials(provider: self.id)
            default:
                throw ScrobbleError.permanent(provider: self.id, reason: msg)
            }
        }

        // Status 2xx, no `error` key → success. Strip outer envelope if present.
        if let single = json.first, json.count == 1, let nested = single.value as? [String: Any] {
            json = nested
        }
        return json
    }

    private func makeRequest(params: [String: String], method: String) throws -> URLRequest {
        let body = self.formEncode(params)
        if method == "GET" {
            var components = URLComponents(url: self.config.endpoint, resolvingAgainstBaseURL: true)
                ?? URLComponents(string: self.config.endpoint.absoluteString)!
            components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let url = components.url else {
                throw ScrobbleError.malformedResponse(provider: self.id, reason: "bad url")
            }
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            return req
        } else {
            var req = URLRequest(url: self.config.endpoint)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.httpBody = Data(body.utf8)
            return req
        }
    }

    private func formEncode(_ params: [String: String]) -> String {
        params
            .sorted { $0.key < $1.key }
            .map { "\(self.escape($0.key))=\(self.escape($0.value))" }
            .joined(separator: "&")
    }

    private func escape(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=?#")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

// MARK: - LastFmCredentialsStore

/// Narrow protocol so the provider doesn't depend on the full `Credentials`
/// surface (and tests can inject in-memory implementations).
public protocol LastFmCredentialsStore: Sendable {
    func lastFmSessionKey() async throws -> String?
    func setLastFmSession(key: String, username: String) async throws
    func clearLastFmSession() async throws
    func lastFmUsername() async throws -> String?
}
