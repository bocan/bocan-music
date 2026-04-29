import Foundation
@testable import Scrobble

// MARK: - StubLock

/// Global async lock so HTTP-stub-based tests can run serially without each
/// suite racing on the shared static `StubProtocol` state.
actor StubLock {
    static let shared = StubLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !self.busy {
            self.busy = true
            return
        }
        await withCheckedContinuation { c in self.waiters.append(c) }
    }

    func release() {
        if let next = waiters.first {
            self.waiters.removeFirst()
            next.resume()
            return
        }
        self.busy = false
    }
}

/// Convenience wrapper that acquires the lock, runs `body`, and always releases.
func withStubLock<T>(_ body: () async throws -> T) async rethrows -> T {
    await StubLock.shared.acquire()
    defer { Task { await StubLock.shared.release() } }
    return try await body()
}

// MARK: - StubProtocol

/// `URLProtocol` subclass that returns canned responses keyed by URL substring.
/// Lifted from `Library/Tests/LRClibClientTests.swift` and tightened for our needs.
final class StubProtocol: URLProtocol {
    /// Per-test-class state. Each test sets routes before constructing the stubbed session.
    nonisolated(unsafe) static var routes: [(matches: (URLRequest) -> Bool, response: () -> (Data, HTTPURLResponse))] = []
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []
    nonisolated(unsafe) static var capturedBodies: [Data] = []

    static func reset() {
        self.routes = []
        self.capturedRequests = []
        self.capturedBodies = []
    }

    static func register(_ matcher: @escaping (URLRequest) -> Bool, _ response: @escaping () -> (Data, HTTPURLResponse)) {
        self.routes.append((matcher, response))
    }

    static func registerJSON(matching substring: String, status: Int = 200, headers: [String: String] = [:], json: Any) {
        self.register({ ($0.url?.absoluteString.contains(substring) ?? false) }, {
            let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
            let url = URL(string: "https://stub")!
            let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (data, resp)
        })
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        StubProtocol.capturedRequests.append(self.request)
        if let stream = request.httpBodyStream {
            stream.open()
            var body = Data()
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buf.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buf, maxLength: 4096)
                if read <= 0 { break }
                body.append(buf, count: read)
            }
            stream.close()
            StubProtocol.capturedBodies.append(body)
        } else {
            StubProtocol.capturedBodies.append(self.request.httpBody ?? Data())
        }
        for route in StubProtocol.routes where route.matches(self.request) {
            let (data, response) = route.response()
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
            return
        }
        self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
    }

    override func stopLoading() {}
}

extension URLSession {
    /// `URLSession` configured to use `StubProtocol` instead of the network.
    static var stubbed: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }
}

// MARK: - In-memory credential stores

actor StubLastFmCreds: LastFmCredentialsStore {
    var sessionKey: String?
    var username: String?
    init(session: String? = nil, user: String? = nil) {
        self.sessionKey = session
        self.username = user
    }

    func lastFmSessionKey() async throws -> String? {
        self.sessionKey
    }

    func setLastFmSession(key: String, username: String) async throws {
        self.sessionKey = key
        self.username = username
    }

    func clearLastFmSession() async throws {
        self.sessionKey = nil
        self.username = nil
    }

    func lastFmUsername() async throws -> String? {
        self.username
    }
}

actor StubListenBrainzCreds: ListenBrainzCredentialsStore {
    var token: String?
    var username: String?
    init(token: String? = nil, user: String? = nil) {
        self.token = token
        self.username = user
    }

    func listenBrainzToken() async throws -> String? {
        self.token
    }

    func setListenBrainz(token: String, username: String) async throws {
        self.token = token
        self.username = username
    }

    func clearListenBrainz() async throws {
        self.token = nil
        self.username = nil
    }

    func listenBrainzUsername() async throws -> String? {
        self.username
    }
}
