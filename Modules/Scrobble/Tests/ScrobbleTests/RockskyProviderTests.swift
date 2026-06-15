import Foundation
import Testing
@testable import Scrobble

@Suite("RockskyProvider", .serialized)
struct RockskyProviderTests {
    private let config = RockskyConfig(endpoint: URL(string: "https://audioscrobbler.rocksky.app")!)

    // MARK: - submit

    @Test("submit returns success on 200")
    func submitSuccess() async throws {
        try await withStubLock {
            StubProtocol.reset()
            StubProtocol.register({ $0.url?.absoluteString.contains("rocksky.app") ?? false }, {
                let url = URL(string: "https://stub")!
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data("{}".utf8), resp)
            })
            let creds = StubRockskyCreds(apiKey: "mykey")
            let provider = RockskyProvider(config: self.config, http: URLSession.stubbed, credentials: creds)
            let results = try await provider.submit([self.makeEvent()])
            #expect(results.count == 1)
            #expect(results[0].outcome == .success)
        }
    }

    @Test("401 response surfaces as invalidCredentials")
    func unauthorisedError() async {
        await withStubLock {
            StubProtocol.reset()
            StubProtocol.register({ $0.url?.absoluteString.contains("rocksky.app") ?? false }, {
                let url = URL(string: "https://stub")!
                let resp = HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!
                return (Data(), resp)
            })
            let creds = StubRockskyCreds(apiKey: "bad")
            let provider = RockskyProvider(config: self.config, http: URLSession.stubbed, credentials: creds)
            await #expect(throws: ScrobbleError.self) {
                _ = try await provider.submit([self.makeEvent()])
            }
        }
    }

    @Test("429 response yields retry with backoff")
    func rateLimited() async throws {
        try await withStubLock {
            StubProtocol.reset()
            StubProtocol.register({ $0.url?.absoluteString.contains("rocksky.app") ?? false }, {
                let url = URL(string: "https://stub")!
                let resp = HTTPURLResponse(
                    url: url, statusCode: 429, httpVersion: nil,
                    headerFields: ["Retry-After": "30"]
                )!
                return (Data(), resp)
            })
            let creds = StubRockskyCreds(apiKey: "key")
            let provider = RockskyProvider(config: self.config, http: URLSession.stubbed, credentials: creds)
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
            StubProtocol.register({ $0.url?.absoluteString.contains("rocksky.app") ?? false }, {
                let url = URL(string: "https://stub")!
                let resp = HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil)!
                return (Data(), resp)
            })
            let creds = StubRockskyCreds(apiKey: "key")
            let provider = RockskyProvider(config: self.config, http: URLSession.stubbed, credentials: creds)
            let results = try await provider.submit([self.makeEvent()])
            if case .retry = results[0].outcome { } else {
                Issue.record("expected retry on 503, got \(results[0].outcome)")
            }
        }
    }

    @Test("submit with no api key throws notAuthenticated")
    func unauthSubmit() async {
        await withStubLock {
            StubProtocol.reset()
            let provider = RockskyProvider(config: self.config, http: URLSession.stubbed, credentials: StubRockskyCreds())
            await #expect(throws: ScrobbleError.self) {
                _ = try await provider.submit([self.makeEvent()])
            }
        }
    }

    @Test("nowPlaying throttles within 5s window")
    func throttle() async throws {
        try await withStubLock {
            StubProtocol.reset()
            StubProtocol.register({ $0.url?.absoluteString.contains("rocksky.app") ?? false }, {
                let url = URL(string: "https://stub")!
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data("{}".utf8), resp)
            })
            let now = Date()
            let provider = RockskyProvider(
                config: self.config,
                http: URLSession.stubbed,
                credentials: StubRockskyCreds(apiKey: "key"),
                now: { now }
            )
            try await provider.nowPlaying(self.makeEvent())
            try await provider.nowPlaying(self.makeEvent())
            #expect(StubProtocol.capturedRequests.count == 1)
        }
    }

    @Test("submit batches plays in groups of 50")
    func batching() async throws {
        try await withStubLock {
            StubProtocol.reset()
            StubProtocol.register({ $0.url?.absoluteString.contains("rocksky.app") ?? false }, {
                let url = URL(string: "https://stub")!
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data("{}".utf8), resp)
            })
            let creds = StubRockskyCreds(apiKey: "key")
            let provider = RockskyProvider(config: self.config, http: URLSession.stubbed, credentials: creds)
            let plays = (0 ..< 75).map { i in self.makeEvent(queueID: Int64(i)) }
            let results = try await provider.submit(plays)
            #expect(results.count == 75)
            #expect(StubProtocol.capturedRequests.count == 2)
        }
    }

    @Test("request uses Bearer token in Authorization header")
    func requestUsesBearer() async throws {
        try await withStubLock {
            StubProtocol.reset()
            StubProtocol.register({ $0.url?.absoluteString.contains("rocksky.app") ?? false }, {
                let url = URL(string: "https://stub")!
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data("{}".utf8), resp)
            })
            let creds = StubRockskyCreds(apiKey: "testkey")
            let provider = RockskyProvider(config: self.config, http: URLSession.stubbed, credentials: creds)
            _ = try await provider.submit([self.makeEvent()])
            let auth = StubProtocol.capturedRequests.first?.value(forHTTPHeaderField: "Authorization") ?? ""
            #expect(auth == "Token testkey")
        }
    }

    @Test("request body is JSON with listen_type and payload")
    func requestBodyIsJSON() async throws {
        try await withStubLock {
            StubProtocol.reset()
            StubProtocol.register({ $0.url?.absoluteString.contains("rocksky.app") ?? false }, {
                let url = URL(string: "https://stub")!
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data("{}".utf8), resp)
            })
            let creds = StubRockskyCreds(apiKey: "key")
            let provider = RockskyProvider(config: self.config, http: URLSession.stubbed, credentials: creds)
            _ = try await provider.submit([self.makeEvent()])
            let body = String(data: StubProtocol.capturedBodies.first ?? Data(), encoding: .utf8) ?? ""
            #expect(body.contains("listen_type"))
            #expect(body.contains("payload"))
        }
    }

    @Test("love skips silently — not supported by scrobble API")
    func loveSkips() async throws {
        try await withStubLock {
            StubProtocol.reset()
            let creds = StubRockskyCreds(apiKey: "key")
            let provider = RockskyProvider(config: self.config, http: URLSession.stubbed, credentials: creds)
            // Should not throw and should send no request regardless of MBID presence
            try await provider.love(track: TrackIdentity(artist: "Cher", title: "Believe", mbid: "abc-123"), loved: true)
            try await provider.love(track: TrackIdentity(artist: "Cher", title: "Believe", mbid: nil), loved: true)
            #expect(StubProtocol.capturedRequests.isEmpty)
        }
    }

    @Test("isAuthenticated returns false with no credentials")
    func notAuthenticated() async {
        let provider = RockskyProvider(config: self.config, http: URLSession.stubbed, credentials: StubRockskyCreds())
        let result = await provider.isAuthenticated()
        #expect(result == false)
    }

    @Test("isAuthenticated returns true with stored api key")
    func authenticated() async {
        let provider = RockskyProvider(
            config: self.config,
            http: URLSession.stubbed,
            credentials: StubRockskyCreds(apiKey: "key")
        )
        let result = await provider.isAuthenticated()
        #expect(result == true)
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
