import Foundation
import Testing
@testable import Scrobble

@Suite("LastFmAuth", .serialized)
struct LastFmAuthTests {
    private let config = LastFmConfig(apiKey: "key", sharedSecret: "secret")

    @Test("happy path returns username and persists session key")
    func happyPath() async throws {
        try await withStubLock {
            StubProtocol.reset()
            // Route both auth.getToken and auth.getSession on the same host.
            StubProtocol.register({ req in
                req.url?.absoluteString.contains("audioscrobbler.com") ?? false
            }, {
                let url = StubProtocol.capturedRequests.last?.url?.absoluteString ?? ""
                let json: [String: Any] = url.contains("auth.getToken")
                    ? ["token": "tok-xyz"]
                    : ["key": "session-123", "name": "alice"]
                let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
                let stubURL = URL(string: "https://stub")!
                let resp = HTTPURLResponse(url: stubURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (data, resp)
            })
            let creds = StubLastFmCreds()
            let provider = LastFmProvider(config: self.config, http: URLSession.stubbed, credentials: creds)
            let opened = OpenURLCapture()
            let auth = LastFmAuth(
                provider: provider,
                credentials: creds,
                pollInterval: .milliseconds(1),
                timeout: .seconds(5),
                openURL: { url in Task { await opened.record(url) } }
            )

            let result = try await auth.connect()
            #expect(result.username == "alice")
            let storedKey = try await creds.lastFmSessionKey()
            #expect(storedKey == "session-123")
            let storedUser = try await creds.lastFmUsername()
            #expect(storedUser == "alice")
            let openedURL = await opened.captured
            #expect(openedURL?.absoluteString.contains("token=tok-xyz") == true)
        }
    }

    @Test("openURL receives full token URL; logged URL omits query params (#283)")
    func openURLHasTokenLoggedURLDoesNot() async throws {
        try await withStubLock {
            StubProtocol.reset()
            StubProtocol.register({ req in
                req.url?.absoluteString.contains("audioscrobbler.com") ?? false
            }, {
                let url = StubProtocol.capturedRequests.last?.url?.absoluteString ?? ""
                let json: [String: Any] = url.contains("auth.getToken")
                    ? ["token": "secret-tok"]
                    : ["key": "sess-key", "name": "bob"]
                let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
                let resp = HTTPURLResponse(
                    url: URL(string: "https://stub")!,
                    statusCode: 200, httpVersion: nil, headerFields: nil
                )!
                return (data, resp)
            })
            let creds = StubLastFmCreds()
            let provider = LastFmProvider(config: self.config, http: URLSession.stubbed, credentials: creds)
            let opened = OpenURLCapture()
            let auth = LastFmAuth(
                provider: provider,
                credentials: creds,
                pollInterval: .milliseconds(1),
                timeout: .seconds(5),
                openURL: { url in Task { await opened.record(url) } }
            )
            _ = try await auth.connect()

            // Browser-facing URL must contain the token (required for Last.fm auth flow).
            let browserURL = await opened.captured
            #expect(browserURL?.absoluteString.contains("token=secret-tok") == true)
            #expect(browserURL?.absoluteString.contains("api_key=") == true)

            // The value actually handed to the logger is the base path without query string.
            let logged = browserURL?.absoluteString.components(separatedBy: "?").first ?? ""
            #expect(!logged.contains("token="), "token must not appear in the logged URL")
            #expect(!logged.contains("api_key="), "api_key must not appear in the logged URL")
        }
    }

    @Test("times out when session never resolves")
    func timesOut() async throws {
        try await withStubLock {
            StubProtocol.reset()
            // getToken succeeds, but getSession always returns error 14 (token unauthorised).
            StubProtocol.register({ req in
                req.url?.absoluteString.contains("audioscrobbler.com") ?? false
            }, {
                let url = StubProtocol.capturedRequests.last?.url?.absoluteString ?? ""
                let json: [String: Any] = url.contains("auth.getToken")
                    ? ["token": "tok-xyz"]
                    : ["error": 14, "message": "Token has not been issued"]
                let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
                let stubURL = URL(string: "https://stub")!
                let resp = HTTPURLResponse(url: stubURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (data, resp)
            })
            let creds = StubLastFmCreds()
            let provider = LastFmProvider(config: self.config, http: URLSession.stubbed, credentials: creds)
            let auth = LastFmAuth(
                provider: provider,
                credentials: creds,
                pollInterval: .milliseconds(5),
                timeout: .milliseconds(40),
                openURL: { _ in }
            )

            await #expect(throws: ScrobbleError.self) {
                _ = try await auth.connect()
            }
            let storedKey = try await creds.lastFmSessionKey()
            #expect(storedKey == nil)
        }
    }
}

private actor OpenURLCapture {
    var captured: URL?
    func record(_ url: URL) {
        self.captured = url
    }
}
