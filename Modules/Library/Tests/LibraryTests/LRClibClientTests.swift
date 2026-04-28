import Foundation
import Metadata
import Testing
@testable import Library

// MARK: - LRClibClient tests

/// Tests are serialized because the stub uses shared static handler state.
@Suite("LRClibClient", .serialized)
struct LRClibClientTests {
    // MARK: - Happy path

    @Test("get returns synced document when syncedLyrics present")
    func getReturnsSynced() async throws {
        let payload = """
        {"syncedLyrics":"[00:01.00]Hello","plainLyrics":"Hello"}
        """
        let session = try URLSession.stubbed(
            for: "lrclib.net",
            body: #require(payload.data(using: .utf8)),
            statusCode: 200
        )
        let client = LRClibClient(session: session)
        let doc = try await client.get(artist: "A", title: "T", album: nil, duration: 180)
        guard case .synced = doc else {
            Issue.record("Expected .synced, got \(String(describing: doc))")
            return
        }
    }

    @Test("get returns unsynced document when only plainLyrics present")
    func getReturnsUnsynced() async throws {
        let payload = """
        {"syncedLyrics":null,"plainLyrics":"Line one"}
        """
        let session = try URLSession.stubbed(
            for: "lrclib.net",
            body: #require(payload.data(using: .utf8)),
            statusCode: 200
        )
        let client = LRClibClient(session: session)
        let doc = try await client.get(artist: "A", title: "T", album: nil, duration: 180)
        guard case let .unsynced(text) = doc else {
            Issue.record("Expected .unsynced, got \(String(describing: doc))")
            return
        }
        #expect(text.contains("Line one"))
    }

    // MARK: - Not-found

    @Test("get returns nil on 404")
    func getReturnsNilOn404() async throws {
        let session = URLSession.stubbed(
            for: "lrclib.net",
            body: Data(),
            statusCode: 404
        )
        let client = LRClibClient(session: session)
        let doc = try await client.get(artist: "A", title: "T", album: nil, duration: 180)
        #expect(doc == nil)
    }

    // MARK: - Rate limit

    @Test("get retries on 429 and eventually returns nil after max attempts")
    func getRetriesOn429() async throws {
        let session = URLSession.stubbed(
            for: "lrclib.net",
            body: Data(),
            statusCode: 429
        )
        let client = LRClibClient(session: session)
        // With 3 attempts all returning 429 → nil
        let doc = try await client.get(artist: "A", title: "T", album: nil, duration: 180)
        #expect(doc == nil)
    }

    // MARK: - Network failure

    @Test("get returns nil on network error without throwing")
    func getReturnsNilOnNetworkError() async throws {
        let session = URLSession.stubbedError(URLError(.notConnectedToInternet))
        let client = LRClibClient(session: session)
        let doc = try await client.get(artist: "A", title: "T", album: nil, duration: 180)
        #expect(doc == nil)
    }

    // MARK: - Search

    @Test("search returns empty array on network error")
    func searchEmptyOnError() async throws {
        let session = URLSession.stubbedError(URLError(.notConnectedToInternet))
        let client = LRClibClient(session: session)
        let results = try await client.search(artist: "A", title: "T", album: nil)
        #expect(results.isEmpty)
    }

    @Test("search returns parsed documents from JSON array")
    func searchParsesDocs() async throws {
        let payload = """
        [{"syncedLyrics":"[00:01.00]Hi","plainLyrics":"Hi"},{"syncedLyrics":null,"plainLyrics":"Plain"}]
        """
        let session = try URLSession.stubbed(
            for: "lrclib.net",
            body: #require(payload.data(using: .utf8)),
            statusCode: 200
        )
        let client = LRClibClient(session: session)
        let results = try await client.search(artist: "A", title: nil, album: nil)
        #expect(results.count == 2)
    }
}

// MARK: - URLSession stub helpers

private class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Data, HTTPURLResponse))?
    nonisolated(unsafe) static var errorHandler: ((URLRequest) -> Error)?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        if let err = Self.errorHandler?(request) {
            client?.urlProtocol(self, didFailWithError: err)
        } else if let (data, response) = Self.handler?(request) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

extension URLSession {
    static func stubbed(for host: String, body: Data, statusCode: Int) -> URLSession {
        StubURLProtocol.handler = { req in
            let resp = HTTPURLResponse(
                url: req.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (body, resp)
        }
        StubURLProtocol.errorHandler = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func stubbedError(_ error: Error) -> URLSession {
        StubURLProtocol.errorHandler = { _ in error }
        StubURLProtocol.handler = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }
}
