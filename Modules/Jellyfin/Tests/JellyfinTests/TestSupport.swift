import Foundation
import JellyfinAPI
import Testing
@testable import Jellyfin

// MARK: - Fixtures

enum Fixture {
    /// The bytes of `Fixtures/<name>.json`.
    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// A fixture decoded into the SDK's own type. The fixtures hold no dates,
    /// so the default decoder is enough.
    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(type, from: self.data(name))
    }
}

// MARK: - Locked

/// A tiny lock-guarded box, so a stub can be `Sendable` and still record calls.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        self.stored = value
    }

    var value: Value {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.stored
    }

    func update(_ body: (inout Value) -> Void) {
        self.lock.lock()
        defer { self.lock.unlock() }
        body(&self.stored)
    }
}

// MARK: - StubJellyfinClient

/// A scripted client for `JellyfinService`, monitor and annotation tests.
final class StubJellyfinClient: JellyfinClientProtocol, @unchecked Sendable {
    let calls = Locked<[String]>([])
    let songQueries = Locked<[JellyfinItemQuery]>([])
    let albumQueries = Locked<[JellyfinItemQuery]>([])
    let artistQueries = Locked<[JellyfinItemQuery]>([])
    let favorites = Locked<[(itemID: String, isFavorite: Bool)]>([])
    let stops = Locked<[(itemID: String, ticks: Int64)]>([])

    var onPing: @Sendable () async throws -> Void = {}
    var onSetFavorite: @Sendable (String, Bool) async throws -> Void = { _, _ in }
    var onSongs: @Sendable (JellyfinItemQuery) async throws -> JellyfinPage<JellyfinSong> = { _ in JellyfinPage(items: []) }
    var onAlbums: @Sendable (JellyfinItemQuery) async throws -> JellyfinPage<JellyfinAlbum> = { _ in JellyfinPage(items: []) }
    var onArtists: @Sendable (JellyfinItemQuery) async throws -> JellyfinPage<JellyfinArtist> = { _ in JellyfinPage(items: []) }
    var onSignOut: @Sendable () async throws -> Void = {}

    private func record(_ name: String) {
        self.calls.update { $0.append(name) }
    }

    func ping() async throws {
        self.record("ping")
        try await self.onPing()
    }

    func serverInfo() async throws -> JellyfinServerInfo {
        self.record("serverInfo")
        return JellyfinServerInfo(serverName: "Stub", version: "10.10.7", serverID: "stub")
    }

    func songs(_ query: JellyfinItemQuery) async throws -> JellyfinPage<JellyfinSong> {
        self.record("songs")
        self.songQueries.update { $0.append(query) }
        return try await self.onSongs(query)
    }

    func albums(_ query: JellyfinItemQuery) async throws -> JellyfinPage<JellyfinAlbum> {
        self.record("albums")
        self.albumQueries.update { $0.append(query) }
        return try await self.onAlbums(query)
    }

    func artists(_ query: JellyfinItemQuery) async throws -> JellyfinPage<JellyfinArtist> {
        self.record("artists")
        self.artistQueries.update { $0.append(query) }
        return try await self.onArtists(query)
    }

    func playlists(_ query: JellyfinItemQuery) async throws -> JellyfinPage<JellyfinPlaylist> {
        self.record("playlists")
        return JellyfinPage(items: [])
    }

    func genres(startIndex: Int, limit: Int?) async throws -> JellyfinPage<JellyfinGenre> {
        self.record("genres")
        return JellyfinPage(items: [])
    }

    func playlistSongs(id: String, startIndex: Int, limit: Int?) async throws -> JellyfinPage<JellyfinSong> {
        self.record("playlistSongs")
        return JellyfinPage(items: [])
    }

    func setFavorite(itemID: String, isFavorite: Bool) async throws {
        self.record("setFavorite")
        self.favorites.update { $0.append((itemID, isFavorite)) }
        try await self.onSetFavorite(itemID, isFavorite)
    }

    func reportPlaybackStarted(itemID: String) async throws {
        self.record("started:\(itemID)")
    }

    func reportPlaybackStopped(itemID: String, positionTicks: Int64) async throws {
        self.record("stopped:\(itemID)")
        self.stops.update { $0.append((itemID, positionTicks)) }
    }

    func signOut() async throws {
        self.record("signOut")
        try await self.onSignOut()
    }

    func streamURL(itemID: String, format: JellyfinStreamFormat, bitrate: JellyfinBitrate) throws -> URL {
        URL(filePath: "/stream/\(itemID)/\(format.rawValue)/\(bitrate.storedValue)")
    }

    func imageURL(itemID: String, tag: String?, maxWidth: Int?) throws -> URL {
        URL(filePath: "/image/\(itemID)/\(tag ?? "-")/\(maxWidth ?? 0)")
    }
}

// MARK: - StubAuthClient

/// A scripted sign-in client for `JellyfinAuth` tests.
final class StubAuthClient: JellyfinAuthClientProtocol, @unchecked Sendable {
    let calls = Locked<[String]>([])
    var quickConnectOn = true
    var onSignIn: @Sendable (String, String) async throws -> JellyfinSession = { name, _ in
        JellyfinSession(userID: "user-1", username: name, accessToken: "token-1")
    }

    var onInitiate: @Sendable () async throws -> JellyfinQuickConnectTicket = {
        JellyfinQuickConnectTicket(code: "123456", secret: "secret-1")
    }

    /// One answer per poll; the last one repeats.
    var pollAnswers: [Result<Bool, any Error>] = [.success(true)]
    private let pollIndex = Locked(0)

    func serverInfo() async throws -> JellyfinServerInfo {
        self.calls.update { $0.append("serverInfo") }
        return JellyfinServerInfo(serverName: "Stub", version: "10.10.7", serverID: "stub")
    }

    func quickConnectEnabled() async throws -> Bool {
        self.calls.update { $0.append("quickConnectEnabled") }
        return self.quickConnectOn
    }

    func signIn(username: String, password: String) async throws -> JellyfinSession {
        self.calls.update { $0.append("signIn") }
        return try await self.onSignIn(username, password)
    }

    func quickConnectInitiate() async throws -> JellyfinQuickConnectTicket {
        self.calls.update { $0.append("initiate") }
        return try await self.onInitiate()
    }

    func quickConnectIsApproved(_ ticket: JellyfinQuickConnectTicket) async throws -> Bool {
        self.calls.update { $0.append("poll") }
        var index = 0
        self.pollIndex.update { index = $0
            $0 += 1
        }
        return try self.pollAnswers[min(index, self.pollAnswers.count - 1)].get()
    }

    func signIn(approved ticket: JellyfinQuickConnectTicket) async throws -> JellyfinSession {
        self.calls.update { $0.append("signInApproved") }
        return JellyfinSession(userID: "user-qc", username: "qc-user", accessToken: "token-qc")
    }
}

// MARK: - StubURLProtocol

/// Answers every request from the SDK client without touching the network.
///
/// The handler is global, so a suite that uses it must be `.serialized`.
class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var body = Data()
        var headers = ["Content-Type": "application/json"]
    }

    private static let state = Locked<(handler: (@Sendable (URLRequest) -> Reply)?, requests: [URLRequest])>((nil, []))

    static var requests: [URLRequest] {
        self.state.value.requests
    }

    static func install(_ handler: @escaping @Sendable (URLRequest) -> Reply) {
        self.state.update { $0 = (handler, []) }
    }

    static func reset() {
        self.state.update { $0 = (nil, []) }
    }

    static var sessionConfiguration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let request = self.request
        var handler: (@Sendable (URLRequest) -> Reply)?
        Self.state.update {
            $0.requests.append(request)
            handler = $0.handler
        }
        let reply = handler?(request) ?? Reply(status: 500)
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: reply.status,
                  httpVersion: "HTTP/1.1",
                  headerFields: reply.headers
              ) else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: reply.body)
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Status helpers

extension JellyfinConnectionStatus {
    var isUnreachable: Bool {
        if case .unreachable = self {
            return true
        }
        return false
    }

    var isServerError: Bool {
        if case .serverError = self {
            return true
        }
        return false
    }
}

// MARK: - Waiting

/// Polls `condition` every 5 ms until it holds or `timeout` passes. Returns whether it held.
/// Real-time waits are kept short and generous, so a slow CI machine does not flake.
func eventually(timeout: Duration = .seconds(3), _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() {
            return true
        }
        do {
            try await Task.sleep(for: .milliseconds(5))
        } catch {
            return condition()
        }
    }
    return condition()
}

// MARK: - Builders

extension JellyfinClientConfiguration {
    static func test(
        url: String = "https://jf.example.test",
        userID: String? = "7f3b1c0e9d2a4e5f8a6b0c1d2e3f4a5b",
        token: String? = "TEST-TOKEN-0123456789"
    ) -> Self {
        Self(
            serverURL: URL(string: url) ?? URL(filePath: "/"),
            deviceID: "DEVICE-1",
            identity: JellyfinClientIdentity(client: "Bocan", deviceName: "Test Mac", version: "9.9"),
            allowSelfSignedTLS: false,
            userID: userID,
            accessToken: token
        )
    }
}
