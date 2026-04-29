import Foundation
import Testing
@testable import Scrobble

@Suite("ListenBrainzProvider", .serialized)
struct ListenBrainzProviderTests {
    @Test("submit success returns successes")
    func submitSuccess() async throws {
        try await withStubLock {
            StubProtocol.reset()
            StubProtocol.registerJSON(matching: "submit-listens", json: ["status": "ok"])
            let creds = StubListenBrainzCreds(token: "tok", user: "alice")
            let provider = ListenBrainzProvider(http: URLSession.stubbed, credentials: creds)
            let results = try await provider.submit([self.makeEvent()])
            #expect(results.count == 1)
            #expect(results[0].outcome == .success)
            let req = StubProtocol.capturedRequests.first
            #expect(req?.value(forHTTPHeaderField: "Authorization") == "Token tok")
        }
    }

    @Test("validate returns username on 200")
    func validateOk() async throws {
        try await withStubLock {
            StubProtocol.reset()
            StubProtocol.registerJSON(matching: "validate-token", json: [
                "code": 200, "message": "Token valid.", "valid": true, "user_name": "alice",
            ])
            let provider = ListenBrainzProvider(http: URLSession.stubbed, credentials: StubListenBrainzCreds())
            let user = try await provider.validate(token: "abc")
            #expect(user == "alice")
        }
    }

    @Test("401 → invalid credentials")
    func unauthorized() async throws {
        try await withStubLock {
            StubProtocol.reset()
            StubProtocol.register({ $0.url?.absoluteString.contains("submit-listens") ?? false }, {
                let url = URL(string: "https://stub")!
                let resp = HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!
                return (Data(), resp)
            })
            let provider = ListenBrainzProvider(http: URLSession.stubbed, credentials: StubListenBrainzCreds(token: "bad"))
            await #expect(throws: ScrobbleError.self) {
                _ = try await provider.submit([self.makeEvent()])
            }
        }
    }

    @Test("429 → retry result")
    func rateLimited() async throws {
        try await withStubLock {
            StubProtocol.reset()
            StubProtocol.register({ $0.url?.absoluteString.contains("submit-listens") ?? false }, {
                let url = URL(string: "https://stub")!
                let resp = HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "10"])!
                return (Data(), resp)
            })
            let provider = ListenBrainzProvider(http: URLSession.stubbed, credentials: StubListenBrainzCreds(token: "tok"))
            let results = try await provider.submit([self.makeEvent()])
            if case let .retry(_, after) = results[0].outcome {
                #expect(after == 10)
            } else {
                Issue.record("expected retry; got \(results[0].outcome)")
            }
        }
    }

    @Test("payload contains track metadata + listened_at")
    func payloadShape() async throws {
        try await withStubLock {
            StubProtocol.reset()
            StubProtocol.registerJSON(matching: "submit-listens", json: ["status": "ok"])
            let provider = ListenBrainzProvider(http: URLSession.stubbed, credentials: StubListenBrainzCreds(token: "tok"))
            _ = try await provider.submit([self.makeEvent()])
            let body = StubProtocol.capturedBodies.first!
            let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            #expect(json["listen_type"] as? String == "single")
            let payload = json["payload"] as! [[String: Any]]
            #expect(payload.count == 1)
            #expect(payload[0]["listened_at"] as? Int == 1_700_000_000)
            let metadata = payload[0]["track_metadata"] as! [String: Any]
            #expect(metadata["track_name"] as? String == "Song")
            #expect(metadata["artist_name"] as? String == "Artist")
        }
    }

    @Test("playing_now omits listened_at")
    func nowPlayingPayload() async throws {
        try await withStubLock {
            StubProtocol.reset()
            StubProtocol.registerJSON(matching: "submit-listens", json: ["status": "ok"])
            let provider = ListenBrainzProvider(http: URLSession.stubbed, credentials: StubListenBrainzCreds(token: "tok"))
            try await provider.nowPlaying(self.makeEvent())
            let body = StubProtocol.capturedBodies.first!
            let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            #expect(json["listen_type"] as? String == "playing_now")
            let listen = (json["payload"] as! [[String: Any]])[0]
            #expect(listen["listened_at"] == nil)
        }
    }

    private func makeEvent() -> PlayEvent {
        PlayEvent(
            queueID: 1, trackID: 1,
            artist: "Artist", album: "Album", title: "Song",
            duration: 200, mbid: nil,
            playedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
