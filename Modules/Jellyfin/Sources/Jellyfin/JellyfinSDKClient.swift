import Foundation
import Get
import JellyfinAPI

// MARK: - JellyfinSDKClient

/// The one implementation of the client seam. It wraps the Jellyfin SDK and is
/// the only place, with the mapping and URL files, that imports it (ADR-097, D6).
///
/// Every SDK error leaves through `JellyfinMapping.error(from:)`, so no caller
/// sees an SDK type, a URL or a token.
final class JellyfinSDKClient: JellyfinClientProtocol, JellyfinAuthClientProtocol, Sendable {
    // MARK: - State

    let client: JellyfinClient
    let userID: String?
    private let deviceID: String

    // MARK: - Init

    /// `sessionConfiguration` is a test seam: a test passes one whose
    /// `protocolClasses` holds a `URLProtocol` stub, so no test touches the network.
    init(configuration: JellyfinClientConfiguration, sessionConfiguration: URLSessionConfiguration = .ephemeral) {
        let sdkConfiguration = JellyfinClient.Configuration(
            url: configuration.serverURL,
            accessToken: configuration.accessToken,
            client: configuration.identity.client,
            deviceName: configuration.identity.deviceName,
            deviceID: configuration.deviceID,
            version: configuration.identity.version
        )
        // The exemption is for this one host. No global trust policy changes.
        let delegate: URLSessionDelegate? = if configuration.allowSelfSignedTLS, let host = configuration.serverURL.host {
            JellyfinHostTrustDelegate(host: host)
        } else {
            nil
        }
        self.client = JellyfinClient(
            configuration: sdkConfiguration,
            sessionConfiguration: sessionConfiguration,
            sessionDelegate: delegate
        )
        self.userID = configuration.userID
        self.deviceID = configuration.deviceID
    }

    // MARK: - Plumbing

    /// Runs `body`, and turns anything it throws into a `JellyfinError`.
    /// Cancellation passes through unchanged so callers can tell it apart.
    @discardableResult
    func run<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw JellyfinMapping.error(from: error)
        }
    }

    func requireUserID() throws -> String {
        guard let userID = self.userID else {
            throw JellyfinError.invalidServerRecord("no user id for this server")
        }
        return userID
    }

    // MARK: - System

    func ping() async throws {
        // `GET /Users/Me` needs the token, so a revoked one answers 401.
        _ = try await self.run { try await self.client.send(Paths.getCurrentUser) }
    }

    func serverInfo() async throws -> JellyfinServerInfo {
        let info = try await self.run { try await self.client.send(Paths.getPublicSystemInfo).value }
        return JellyfinMapping.serverInfo(info)
    }

    // MARK: - Writes

    func setFavorite(itemID: String, isFavorite: Bool) async throws {
        let userID = try self.requireUserID()
        let request = isFavorite
            ? Paths.markFavoriteItem(itemID: itemID, userID: userID)
            : Paths.unmarkFavoriteItem(itemID: itemID, userID: userID)
        _ = try await self.run { try await self.client.send(request) }
    }

    func reportPlaybackStarted(itemID: String) async throws {
        let body = PlaybackStateInfo(
            canSeek: true,
            itemID: itemID,
            playMethod: .directStream,
            positionTicks: 0
        )
        try await self.run { try await self.client.send(Paths.reportPlaybackStart(body)) }
    }

    func reportPlaybackStopped(itemID: String, positionTicks: Int64) async throws {
        let body = PlaybackStopInfo(itemID: itemID, positionTicks: Int(positionTicks))
        try await self.run { try await self.client.send(Paths.reportPlaybackStopped(body)) }
    }

    func signOut() async throws {
        try await self.run { try await self.client.signOut() }
    }

    // MARK: - URLs (never log these)

    func streamURL(itemID: String, format: JellyfinStreamFormat, bitrate: JellyfinBitrate) throws -> URL {
        let request = JellyfinStreamURL.request(
            itemID: itemID,
            format: format,
            bitrate: bitrate,
            deviceID: self.deviceID
        )
        guard let url = self.client.url(with: request, queryAPIKey: true) else {
            throw JellyfinError.invalidURL("stream")
        }
        return url
    }

    func imageURL(itemID: String, tag: String?, maxWidth: Int?) throws -> URL {
        let request = Paths.getItemImage(
            itemID: itemID,
            imageType: "Primary",
            parameters: .init(maxWidth: maxWidth, tag: tag)
        )
        guard let url = self.client.url(with: request, queryAPIKey: true) else {
            throw JellyfinError.invalidURL("image")
        }
        return url
    }

    // MARK: - Auth

    func quickConnectEnabled() async throws -> Bool {
        let data = try await self.run { try await self.client.data(for: Paths.getQuickConnectEnabled).value }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "true"
    }

    func signIn(username: String, password: String) async throws -> JellyfinSession {
        let result = try await self.run { try await self.client.signIn(username: username, password: password) }
        return try Self.session(from: result, fallbackName: username)
    }

    func quickConnectInitiate() async throws -> JellyfinQuickConnectTicket {
        let result = try await self.run { try await self.client.send(Paths.initiateQuickConnect).value }
        guard let code = result.code, let secret = result.secret else {
            throw JellyfinError.decoding("the server gave no Quick Connect code")
        }
        return JellyfinQuickConnectTicket(code: code, secret: secret)
    }

    func quickConnectIsApproved(_ ticket: JellyfinQuickConnectTicket) async throws -> Bool {
        let result = try await self.run {
            try await self.client.send(Paths.getQuickConnectState(secret: ticket.secret)).value
        }
        return result.isAuthenticated ?? false
    }

    func signIn(approved ticket: JellyfinQuickConnectTicket) async throws -> JellyfinSession {
        let result = try await self.run { try await self.client.signIn(quickConnectSecret: ticket.secret) }
        return try Self.session(from: result, fallbackName: nil)
    }

    private static func session(from result: AuthenticationResult, fallbackName: String?) throws -> JellyfinSession {
        guard let token = result.accessToken, !token.isEmpty else {
            throw JellyfinError.noAccessToken
        }
        guard let userID = result.user?.id else {
            throw JellyfinError.decoding("the server gave no user id")
        }
        return JellyfinSession(
            userID: userID,
            username: result.user?.name ?? fallbackName ?? "",
            accessToken: token
        )
    }
}

// MARK: - JellyfinHostTrustDelegate

/// Lets one named host present a self-signed certificate. Host-scoped: every
/// other host and every other challenge gets default handling.
final class JellyfinHostTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let host: String

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
