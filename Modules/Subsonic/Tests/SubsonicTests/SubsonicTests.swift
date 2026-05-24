import Foundation
import SwiftSonic
import Testing
@testable import Subsonic

// MARK: - StubHTTPTransport

/// A minimal stub transport for unit tests. Enqueue responses in order.
final class StubHTTPTransport: HTTPTransport, @unchecked Sendable {
    private var responses: [(Data, Int)] = []
    private var errors: [Error] = []
    private(set) var requestCount = 0
    private(set) var lastRequest: URLRequest?

    func enqueue(json: String, statusCode: Int = 200) {
        let data = Data(json.utf8)
        self.responses.append((data, statusCode))
    }

    func enqueueError(_ error: Error) {
        self.errors.append(error)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        self.requestCount += 1
        self.lastRequest = request

        if !self.errors.isEmpty {
            throw self.errors.removeFirst()
        }

        guard !self.responses.isEmpty else {
            throw URLError(.badServerResponse)
        }
        let (data, statusCode) = self.responses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://test.local")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}

// MARK: - Helpers

private let testServerURL = URL(string: "https://music.test.local")!
private let testServerID = UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000001")!

/// Minimal OK ping envelope (empty subsonic-response with status=ok).
private let pingOK = """
{
    "subsonic-response": {
        "status": "ok",
        "version": "1.16.1"
    }
}
"""

/// 401-equivalent API error (wrong credentials — Subsonic error code 40).
private let authError = """
{
    "subsonic-response": {
        "status": "failed",
        "version": "1.16.1",
        "error": { "code": 40, "message": "Wrong username or password." }
    }
}
"""

/// Helper that builds a minimal `ServerConfiguration`.
private func testConfig() -> ServerConfiguration {
    ServerConfiguration(
        serverURL: testServerURL,
        auth: .tokenAuth(username: "alice", password: "s3cr3t", reusesSalt: false)
    )
}

// MARK: - SubsonicServiceTests

@Suite("SubsonicService")
struct SubsonicServiceTests {
    // MARK: - Ping

    @Test("ping succeeds when server returns 200 OK envelope")
    func pingSuccess() async throws {
        let transport = StubHTTPTransport()
        transport.enqueue(json: pingOK)
        let config = testConfig()
        let client = SwiftSonicClient(configuration: config, transport: transport)
        // Direct client ping — service wraps this but the transport is the key moving part.
        try await client.ping()
        #expect(transport.requestCount == 1)
    }

    @Test("ping throws transient SwiftSonicError on network failure")
    func pingNetworkFailure() async throws {
        let transport = StubHTTPTransport()
        transport.enqueueError(URLError(.networkConnectionLost))
        let config = testConfig()
        let client = SwiftSonicClient(
            configuration: config,
            transport: transport,
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: 0)
        )
        do {
            try await client.ping()
            Issue.record("Expected error not thrown")
        } catch let e as SwiftSonicError {
            #expect(e.isTransient)
        }
    }

    @Test("auth error is classified as authentication failure")
    func authErrorClassification() async throws {
        let transport = StubHTTPTransport()
        transport.enqueue(json: authError)
        let config = testConfig()
        let client = SwiftSonicClient(
            configuration: config,
            transport: transport,
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: 0)
        )
        do {
            try await client.ping()
            Issue.record("Expected auth error not thrown")
        } catch let e as SwiftSonicError {
            #expect(e.isAuthenticationFailure)
        }
    }

    // MARK: - SubsonicError mapping

    @Test("SubsonicError.transport preserves isTransient from SwiftSonicError")
    func errorMappingTransient() {
        let inner = SwiftSonicError.network(URLError(.networkConnectionLost))
        let outer = SubsonicError.transport(inner)
        #expect(outer.isTransient)
    }

    @Test("SubsonicError.transport preserves isAuthenticationFailure")
    func errorMappingAuth() {
        // Test the apiError path — API error code 40 = wrong credentials
        let outer = SubsonicError.apiError(code: 40, message: "Wrong credentials")
        #expect(outer.isAuthenticationFailure)
    }

    @Test("SubsonicError.unknownServer has non-nil localizedDescription")
    func unknownServerDescription() {
        let err = SubsonicError.unknownServer(UUID())
        #expect(err.errorDescription != nil)
    }
}

// MARK: - SubsonicConnectionStatusTests

@Suite("SubsonicConnectionStatus")
struct SubsonicConnectionStatusTests {
    @Test("online status reports isOnline == true")
    func onlineIsOnline() {
        let s = SubsonicConnectionStatus.online(lastPing: Date())
        #expect(s.isOnline)
    }

    @Test("non-online statuses report isOnline == false")
    func nonOnlineStatuses() {
        let statuses: [SubsonicConnectionStatus] = [
            .unknown,
            .connecting,
            .authFailed("test"),
            .unreachable("test"),
            .serverError("test"),
        ]
        for s in statuses {
            #expect(!s.isOnline, "Expected \(s) to not be online")
        }
    }

    @Test("authFailed requires user action")
    func authFailedRequiresAction() {
        let s = SubsonicConnectionStatus.authFailed("Bad password")
        #expect(s.requiresUserAction)
    }

    @Test("other statuses do not require user action")
    func othersDoNotRequireAction() {
        let statuses: [SubsonicConnectionStatus] = [
            .unknown, .connecting, .online(lastPing: Date()), .unreachable(""), .serverError(""),
        ]
        for s in statuses {
            #expect(!s.requiresUserAction)
        }
    }

    @Test("localizedDescription is non-empty for all cases")
    func allCasesHaveDescription() {
        let statuses: [SubsonicConnectionStatus] = [
            .unknown, .connecting, .online(lastPing: Date()),
            .authFailed("x"), .unreachable("y"), .serverError("z"),
        ]
        for s in statuses {
            #expect(!s.localizedDescription.isEmpty)
        }
    }

    @Test("Equatable: identical cases are equal")
    func equatable() {
        let date = Date(timeIntervalSince1970: 1000)
        #expect(SubsonicConnectionStatus.online(lastPing: date) == .online(lastPing: date))
        #expect(SubsonicConnectionStatus.authFailed("x") == .authFailed("x"))
        #expect(SubsonicConnectionStatus.unknown == .unknown)
    }
}

// MARK: - SubsonicCapabilitiesTests

@Suite("SubsonicCapabilities")
struct SubsonicCapabilitiesTests {
    @Test("from(ServerCapabilities) maps fields correctly")
    func fromServerCapabilities() {
        let raw = ServerCapabilities(
            apiVersion: "1.16.1",
            isOpenSubsonic: true,
            serverType: "navidrome",
            serverVersion: "0.50.2",
            extensions: [
                "songLyrics": [1],
                "apiKeyAuthentication": [1],
                "randomSongsByGenre": [1],
            ]
        )
        let caps = SubsonicCapabilities.from(raw)
        #expect(caps.apiVersion == "1.16.1")
        #expect(caps.isOpenSubsonic)
        #expect(caps.serverType == "navidrome")
        #expect(caps.serverVersion == "0.50.2")
        #expect(caps.supportsLyricsBySongId)
        #expect(caps.supportsApiKey)
        #expect(caps.supportsRandomSongsByGenre)
        #expect(!caps.supportsPodcasts)
    }

    @Test("isStale returns false for freshly created capabilities")
    func freshIsNotStale() {
        let caps = SubsonicCapabilities(fetchedAt: Date())
        #expect(!caps.isStale)
    }

    @Test("isStale returns true for capabilities older than 24h")
    func oldIsStale() {
        let old = Date(timeIntervalSinceNow: -90000) // 25 h ago
        let caps = SubsonicCapabilities(fetchedAt: old)
        #expect(caps.isStale)
    }

    @Test("markUnsupported clears the correct capability flag")
    func markUnsupported() {
        var caps = SubsonicCapabilities(
            supportsLyricsBySongId: true,
            supportsApiKey: true,
            supportsPodcasts: true
        )
        caps.markUnsupported("songLyrics")
        caps.markUnsupported("podcasts")
        #expect(!caps.supportsLyricsBySongId)
        #expect(!caps.supportsPodcasts)
        #expect(caps.supportsApiKey) // unchanged
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let caps = SubsonicCapabilities(
            serverType: "gonic",
            apiVersion: "1.13.0",
            isOpenSubsonic: false,
            supportsBookmarks: true
        )
        let data = try JSONEncoder().encode(caps)
        let decoded = try JSONDecoder().decode(SubsonicCapabilities.self, from: data)
        #expect(decoded.serverType == "gonic")
        #expect(decoded.isOpenSubsonic == false)
        #expect(decoded.supportsBookmarks)
    }
}

// MARK: - SubsonicServerModelTests

@Suite("SubsonicServer model")
struct SubsonicServerModelTests {
    @Test("normalises trailing slashes from serverURL on init")
    func normaliseTrailingSlash() throws {
        let server = try SubsonicServer(
            name: "Home",
            serverURL: #require(URL(string: "https://music.home.local///")),
            authKind: .tokenSalt,
            username: "bob"
        )
        #expect(server.serverURL.absoluteString == "https://music.home.local")
    }

    @Test("keychainAccount defaults to id.uuidString when not provided")
    func keychainAccountDefault() throws {
        let server = try SubsonicServer(
            name: "Home",
            serverURL: #require(URL(string: "https://music.home.local")),
            authKind: .apiKey
        )
        #expect(server.keychainAccount == server.id.uuidString)
    }

    @Test("SubsonicBitrate round-trips through storedValue")
    func bitrateRoundTrip() {
        let cases: [(SubsonicBitrate, String)] = [
            (.original, "original"),
            (.kbps(128), "128"),
            (.kbps(320), "320"),
        ]
        for (bitrate, stored) in cases {
            #expect(bitrate.storedValue == stored)
            let recovered = SubsonicBitrate(storedValue: stored)
            switch (bitrate, recovered) {
            case (.original, .original): break
            case let (.kbps(a), .kbps(b)): #expect(a == b)
            default: Issue.record("Round-trip mismatch for \(stored)")
            }
        }
    }

    @Test("SubsonicBitrate.original has nil intValue")
    func bitrateOriginalIntValue() {
        #expect(SubsonicBitrate.original.intValue == nil)
    }

    @Test("SubsonicBitrate.kbps(256) has intValue 256")
    func bitrateKbpsIntValue() {
        #expect(SubsonicBitrate.kbps(256).intValue == 256)
    }

    @Test("SubsonicStreamFormat rawValues match Subsonic API strings")
    func streamFormatRawValues() {
        #expect(SubsonicStreamFormat.mp3.rawValue == "mp3")
        #expect(SubsonicStreamFormat.opus.rawValue == "opus")
        #expect(SubsonicStreamFormat.aac.rawValue == "aac")
        #expect(SubsonicStreamFormat.flac.rawValue == "flac")
        #expect(SubsonicStreamFormat.original.rawValue == "original")
    }

    @Test("SubsonicStreamFormat.original has nil requestValue")
    func streamFormatOriginalRequestValue() {
        #expect(SubsonicStreamFormat.original.requestValue == nil)
    }
}
