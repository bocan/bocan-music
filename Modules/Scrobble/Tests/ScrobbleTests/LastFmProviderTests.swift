import Foundation
import Testing
@testable import Scrobble

@Suite("LastFmProvider", .serialized)
struct LastFmProviderTests {
    private let config = LastFmConfig(apiKey: "key", sharedSecret: "secret")

    @Test("submit returns success when service replies ok")
    func submitSuccess() async throws {
        try await withStubLock {
            StubProtocol.reset()
            StubProtocol.registerJSON(matching: "audioscrobbler.com", json: [
                "scrobbles": ["@attr": ["accepted": 1, "ignored": 0]],
            ])
            let creds = StubLastFmCreds(session: "sk", user: "user")
            let provider = LastFmProvider(config: self.config, http: URLSession.stubbed, credentials: creds)
            let results = try await provider.submit([self.makeEvent()])
            #expect(results.count == 1)
            #expect(results[0].outcome == .success)
        }
    }

    @Test("error code 9 surfaces as invalidCredentials")
    func invalidSessionError() async throws {
        try await withStubLock {
            StubProtocol.reset()
            StubProtocol.registerJSON(matching: "audioscrobbler.com", status: 200, json: [
                "error": 9, "message": "Invalid session key",
            ])
            let creds = StubLastFmCreds(session: "bad", user: "u")
            let provider = LastFmProvider(config: self.config, http: URLSession.stubbed, credentials: creds)
            await #expect(throws: ScrobbleError.self) {
                _ = try await provider.submit([self.makeEvent()])
            }
        }
    }

    @Test("error code 29 yields retry with backoff")
    func rateLimited() async throws {
        try await withStubLock {
            StubProtocol.reset()
            StubProtocol.registerJSON(matching: "audioscrobbler.com", status: 200, headers: ["Retry-After": "30"], json: [
                "error": 29, "message": "Rate limit",
            ])
            let creds = StubLastFmCreds(session: "sk", user: "u")
            let provider = LastFmProvider(config: self.config, http: URLSession.stubbed, credentials: creds)
            let results = try await provider.submit([self.makeEvent()])
            #expect(results.count == 1)
            if case let .retry(_, after) = results[0].outcome {
                #expect(after == 30)
            } else {
                Issue.record("expected retry, got \(results[0].outcome)")
            }
        }
    }

    @Test("HTTP 5xx yields retry")
    func transient5xx() async throws {
        try await withStubLock {
            StubProtocol.reset()
            StubProtocol.register({ $0.url?.absoluteString.contains("audioscrobbler.com") ?? false }, {
                let url = URL(string: "https://stub")!
                let resp = HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil)!
                return (Data("server error".utf8), resp)
            })
            let creds = StubLastFmCreds(session: "sk", user: "u")
            let provider = LastFmProvider(config: self.config, http: URLSession.stubbed, credentials: creds)
            let results = try await provider.submit([self.makeEvent()])
            if case .retry = results[0].outcome { } else {
                Issue.record("expected retry on 503, got \(results[0].outcome)")
            }
        }
    }

    @Test("submit with no session throws notAuthenticated")
    func unauthSubmit() async throws {
        try await withStubLock {
            StubProtocol.reset()
            let provider = LastFmProvider(config: self.config, http: URLSession.stubbed, credentials: StubLastFmCreds())
            await #expect(throws: ScrobbleError.self) {
                _ = try await provider.submit([self.makeEvent()])
            }
        }
    }

    @Test("nowPlaying throttles within 5s window")
    func throttle() async throws {
        try await withStubLock {
            StubProtocol.reset()
            StubProtocol.registerJSON(matching: "audioscrobbler.com", json: ["nowplaying": [:]])
            let now = Date()
            let provider = LastFmProvider(
                config: self.config,
                http: URLSession.stubbed,
                credentials: StubLastFmCreds(session: "sk"),
                now: { now }
            )
            try await provider.nowPlaying(self.makeEvent())
            try await provider.nowPlaying(self.makeEvent())
            #expect(StubProtocol.capturedRequests.count == 1)
        }
    }

    @Test("requestSession round-trips username + key")
    func sessionExchange() async throws {
        try await withStubLock {
            StubProtocol.reset()
            StubProtocol.registerJSON(matching: "audioscrobbler.com", json: [
                "session": ["key": "abc123", "name": "alice", "subscriber": 0],
            ])
            let provider = LastFmProvider(config: self.config, http: URLSession.stubbed, credentials: StubLastFmCreds())
            let result = try await provider.requestSession(token: "tok")
            #expect(result.sessionKey == "abc123")
            #expect(result.username == "alice")
        }
    }

    @Test("submit batches plays in groups of 50")
    func batching() async throws {
        try await withStubLock {
            StubProtocol.reset()
            StubProtocol.registerJSON(matching: "audioscrobbler.com", json: ["scrobbles": ["@attr": ["accepted": 1]]])
            let creds = StubLastFmCreds(session: "sk")
            let provider = LastFmProvider(config: self.config, http: URLSession.stubbed, credentials: creds)
            let plays = (0 ..< 75).map { i in self.makeEvent(queueID: Int64(i)) }
            let results = try await provider.submit(plays)
            #expect(results.count == 75)
            #expect(StubProtocol.capturedRequests.count == 2)
        }
    }

    private func makeEvent(queueID: Int64 = 1) -> PlayEvent {
        PlayEvent(
            queueID: queueID, trackID: 100,
            artist: "Cher", album: "Believe", title: "Believe",
            duration: 240, mbid: nil,
            playedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
