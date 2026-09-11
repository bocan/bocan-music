import Foundation
import Observability
import Testing
@testable import Podcasts

// MARK: - MockHTTPClient

final class MockHTTPClient: HTTPClient, @unchecked Sendable {
    var handler: (URLRequest) async throws -> (Data, URLResponse) = { _ in
        (Data(), HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await self.handler(request)
    }
}

/// Thread-safe capture of requests seen by a mock handler.
final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []

    var requests: [URLRequest] {
        self.lock.withLock { self._requests }
    }

    func record(_ request: URLRequest) {
        self.lock.withLock { self._requests.append(request) }
    }
}

private func makeHTTPResponse(
    url: URL = URL(string: "https://example.com/feed")!,
    status: Int,
    headers: [String: String] = [:]
) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
}

@Suite("FeedFetcher")
struct FeedFetcherTests {
    @Test("200 response returns data and no notModified flag")
    func successfulFetch() async throws {
        let mock = MockHTTPClient()
        let expectedData = "<?xml version='1.0'?><rss/>".data(using: .utf8)!
        mock.handler = { _ in
            (expectedData, makeHTTPResponse(status: 200, headers: ["ETag": "\"abc123\""]))
        }
        let fetcher = FeedFetcher(http: mock)
        let result = try await fetcher.fetch(
            #require(URL(string: "https://example.com/feed")),
            etag: nil,
            lastModified: nil
        )
        #expect(result.data == expectedData)
        #expect(result.notModified == false)
        #expect(result.etag == "\"abc123\"")
    }

    @Test("304 Not Modified returns notModified without data")
    func notModifiedResponse() async throws {
        let mock = MockHTTPClient()
        mock.handler = { _ in
            (Data(), makeHTTPResponse(status: 304))
        }
        let fetcher = FeedFetcher(http: mock)
        let result = try await fetcher.fetch(
            #require(URL(string: "https://example.com/feed")),
            etag: "\"prev-etag\"",
            lastModified: nil
        )
        #expect(result.notModified == true)
        #expect(result.data == nil)
    }

    @Test("If-None-Match header is sent when etag provided")
    func etagSentInRequest() async throws {
        let mock = MockHTTPClient()
        var capturedRequest: URLRequest?
        mock.handler = { req in
            capturedRequest = req
            return (Data(), makeHTTPResponse(status: 304))
        }
        let fetcher = FeedFetcher(http: mock)
        _ = try? await fetcher.fetch(
            try #require(URL(string: "https://example.com/feed")),
            etag: "\"abc\"",
            lastModified: nil
        )
        #expect(capturedRequest?.value(forHTTPHeaderField: "If-None-Match") == "\"abc\"")
    }

    @Test("If-Modified-Since header is sent when lastModified provided")
    func lastModifiedSentInRequest() async throws {
        let mock = MockHTTPClient()
        var capturedRequest: URLRequest?
        mock.handler = { req in
            capturedRequest = req
            return (Data(), makeHTTPResponse(status: 304))
        }
        let fetcher = FeedFetcher(http: mock)
        _ = try? await fetcher.fetch(
            try #require(URL(string: "https://example.com/feed")),
            etag: nil,
            lastModified: "Mon, 01 Jan 2024 00:00:00 GMT"
        )
        #expect(
            capturedRequest?.value(forHTTPHeaderField: "If-Modified-Since")
                == "Mon, 01 Jan 2024 00:00:00 GMT"
        )
    }

    @Test("User-Agent header is the shared canonical agent, not the legacy string")
    func userAgentSent() async throws {
        let mock = MockHTTPClient()
        var capturedRequest: URLRequest?
        mock.handler = { req in
            capturedRequest = req
            return (Data(), makeHTTPResponse(status: 200))
        }
        let fetcher = FeedFetcher(http: mock)
        _ = try? await fetcher.fetch(
            try #require(URL(string: "https://example.com/feed")),
            etag: nil,
            lastModified: nil
        )
        let ua = capturedRequest?.value(forHTTPHeaderField: "User-Agent")
        #expect(ua == UserAgent.string)
        #expect(ua?.contains("cloudcauldron") == false)
        #expect(ua?.contains("Podcast-Reader") == false)
    }

    @Test("404 response throws httpStatus error")
    func notFoundThrows() async throws {
        let mock = MockHTTPClient()
        mock.handler = { _ in (Data(), makeHTTPResponse(status: 404)) }
        let fetcher = FeedFetcher(http: mock)
        do {
            _ = try await fetcher.fetch(
                #require(URL(string: "https://example.com/feed")),
                etag: nil, lastModified: nil
            )
            Issue.record("Expected httpStatus error to be thrown")
        } catch let PodcastsError.httpStatus(code, _) {
            #expect(code == 404)
        }
    }

    @Test("Response exceeding maxBytes throws feedTooLarge")
    func overSizedResponseThrows() async throws {
        let mock = MockHTTPClient()
        let bigData = Data(count: 1024 + 1)
        mock.handler = { _ in (bigData, makeHTTPResponse(status: 200)) }
        let fetcher = FeedFetcher(http: mock, maxBytes: 1024)
        do {
            _ = try await fetcher.fetch(
                #require(URL(string: "https://example.com/feed")),
                etag: nil, lastModified: nil
            )
            Issue.record("Expected feedTooLarge error to be thrown")
        } catch let PodcastsError.feedTooLarge(bytes) {
            #expect(bytes > 1024)
        }
    }

    @Test("Network error is wrapped in PodcastsError.network")
    func networkErrorWrapped() async throws {
        let mock = MockHTTPClient()
        mock.handler = { _ in throw URLError(.notConnectedToInternet) }
        let fetcher = FeedFetcher(http: mock)
        do {
            _ = try await fetcher.fetch(
                #require(URL(string: "https://example.com/feed")),
                etag: nil, lastModified: nil
            )
            Issue.record("Expected network error to be thrown")
        } catch PodcastsError.network {
            // expected
        }
    }

    @Test("ETag from response is returned in FeedFetchResult")
    func etagCapturedFromResponse() async throws {
        let mock = MockHTTPClient()
        mock.handler = { _ in
            (Data("x".utf8), makeHTTPResponse(
                status: 200,
                headers: ["ETag": "\"v2\"", "Last-Modified": "Wed, 10 Jan 2024 00:00:00 GMT"]
            ))
        }
        let fetcher = FeedFetcher(http: mock, maxBytes: 1024)
        let result = try await fetcher.fetch(
            #require(URL(string: "https://example.com/feed")),
            etag: nil, lastModified: nil
        )
        #expect(result.etag == "\"v2\"")
        #expect(result.lastModified == "Wed, 10 Jan 2024 00:00:00 GMT")
    }

    @Test("Content-Length header exceeding cap throws feedTooLarge before body is read")
    func contentLengthHeaderCheck() async throws {
        let mock = MockHTTPClient()
        mock.handler = { _ in
            let headers = ["Content-Length": "2000"]
            return (Data(count: 100), makeHTTPResponse(status: 200, headers: headers))
        }
        let fetcher = FeedFetcher(http: mock, maxBytes: 1024)
        do {
            _ = try await fetcher.fetch(
                #require(URL(string: "https://example.com/feed")),
                etag: nil, lastModified: nil
            )
            Issue.record("Expected feedTooLarge error to be thrown")
        } catch let PodcastsError.feedTooLarge(bytes) {
            #expect(bytes == 2000)
        }
    }

    @Test("Plain-http remote feed URL is upgraded to https before the request")
    func plainHttpRemoteUpgradedToHttps() async throws {
        let mock = MockHTTPClient()
        let seen = RequestRecorder()
        let body = "<?xml version='1.0'?><rss/>".data(using: .utf8)!
        let expectedUpgraded = #require(URL(string: "https://podcast.example.org/feed?x=1"))
        mock.handler = { request in
            seen.record(request)
            return (body, makeHTTPResponse(url: expectedUpgraded, status: 200))
        }
        let fetcher = FeedFetcher(http: mock)
        let result = try await fetcher.fetch(
            #require(URL(string: "http://podcast.example.org/feed?x=1")),
            etag: nil,
            lastModified: nil
        )
        let requested = #require(seen.requests.last?.url)
        #expect(requested.scheme == "https")
        #expect(requested.host == "podcast.example.org")
        #expect(requested.path == "/feed")
        #expect(requested.query == "x=1")
        #expect(result.data == body)
        #expect(result.finalURL == expectedUpgraded)
    }

    @Test("Loopback plain-http feed URL is kept as http")
    func loopbackPlainHttpKept() async throws {
        let mock = MockHTTPClient()
        let seen = RequestRecorder()
        let expectedKept = #require(URL(string: "http://127.0.0.1:8090/feed"))
        mock.handler = { request in
            seen.record(request)
            return (Data("<rss/>".utf8), makeHTTPResponse(url: expectedKept, status: 200))
        }
        let fetcher = FeedFetcher(http: mock)
        _ = try await fetcher.fetch(expectedKept, etag: nil, lastModified: nil)
        let requested = #require(seen.requests.last?.url)
        #expect(requested == expectedKept)
        #expect(requested.scheme == "http")
    }

    @Test("httpsUpgraded leaves non-http schemes unchanged")
    func httpsUpgradedNonHttp() {
        let fileURL = URL(fileURLWithPath: "/tmp/feed.xml")
        #expect(FeedFetcher.httpsUpgraded(fileURL) == fileURL)

        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "example.org"
        comps.path = "/feed"
        guard let httpsURL = comps.url else {
            Issue.record("https URL fixture failed to build")
            return
        }
        #expect(FeedFetcher.httpsUpgraded(httpsURL) == httpsURL)
    }
}
