import Foundation
import Observability

// MARK: - LastFmAuth

/// Implements the desktop authentication flow:
///
/// 1. Call `auth.getToken` → token.
/// 2. Open `https://www.last.fm/api/auth/?api_key=…&token=…` in the user's browser.
/// 3. Poll `auth.getSession` every 5 s until the user authorises (or we time out).
/// 4. Persist the returned `(session_key, username)` via the credentials store.
public actor LastFmAuth {
    public struct Result: Sendable, Equatable {
        public let username: String
    }

    public enum State: Sendable, Equatable {
        case idle
        case waitingForUser(token: String)
        case completed(Result)
        case failed(message: String)
    }

    private let provider: LastFmProvider
    private let credentials: any LastFmCredentialsStore
    private let log = AppLogger.make(.scrobble)
    private let pollInterval: Duration
    private let timeout: Duration
    private let openURL: @Sendable (URL) -> Void

    public init(
        provider: LastFmProvider,
        credentials: any LastFmCredentialsStore,
        pollInterval: Duration = .seconds(5),
        timeout: Duration = .seconds(300),
        openURL: @escaping @Sendable (URL) -> Void
    ) {
        self.provider = provider
        self.credentials = credentials
        self.pollInterval = pollInterval
        self.timeout = timeout
        self.openURL = openURL
    }

    /// Run the full flow. Returns the resolved username, or throws.
    /// `Task.cancel()` aborts the poll loop cleanly.
    public func connect() async throws -> Result {
        let token = try await self.provider.requestAuthToken()
        let url = self.provider.authorisationURL(forToken: token)
        self.openURL(url)
        self.log.info("scrobble.lastfm.auth.opened", ["url": url.absoluteString])

        let deadline = ContinuousClock.now.advanced(by: self.timeout)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: self.pollInterval)
            do {
                let session = try await self.provider.requestSession(token: token)
                try await self.credentials.setLastFmSession(key: session.sessionKey, username: session.username)
                self.log.info("scrobble.lastfm.auth.ok", ["user": session.username])
                return Result(username: session.username)
            } catch ScrobbleError.invalidCredentials, ScrobbleError.permanent {
                // User hasn't authorised yet — keep polling.
                continue
            } catch let ScrobbleError.malformedResponse(_, reason) {
                self.log.warning("scrobble.lastfm.auth.poll", ["reason": reason])
                continue
            }
        }
        throw ScrobbleError.authTimeout
    }
}
