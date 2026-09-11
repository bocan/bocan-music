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

    @Test("Plain-http remote feed URL is tried over https first, and once when that works")
    func plainHttpRemoteUpgradedToHttps() async throws {
        let mock = MockHTTPClient()
        let seen = RequestRecorder()
        let body = "<?xml version='1.0'?><rss/>".data(using: .utf8)!
        let expectedUpgraded = try #require(URL(string: "https://podcast.example.org/feed?x=1"))
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
        let requested = try #require(seen.requests.last?.url)
        #expect(seen.requests.count == 1, "no retry when the https twin serves the feed")
        #expect(requested.scheme == "https")
        #expect(requested.host == "podcast.example.org")
        #expect(requested.path == "/feed")
        #expect(requested.query == "x=1")
        #expect(result.data == body)
        #expect(result.finalURL == expectedUpgraded)
    }

    @Test("When the https twin fails to connect, the URL is retried as given and its answer returned")
    func httpsConnectionFailureRetriesOriginal() async throws {
        let mock = MockHTTPClient()
        let seen = RequestRecorder()
        let body = Data("<rss/>".utf8)
        let original = try #require(URL(string: "http://192.168.1.10:8000/feed.xml"))
        mock.handler = { request in
            seen.record(request)
            if request.url?.scheme == "https" {
                throw URLError(.secureConnectionFailed)
            }
            return (body, makeHTTPResponse(url: original, status: 200))
        }
        let fetcher = FeedFetcher(http: mock)
        let result = try await fetcher.fetch(original, etag: nil, lastModified: nil)
        #expect(seen.requests.map(\.url?.scheme) == ["https", "http"])
        #expect(seen.requests.last?.url == original)
        #expect(result.data == body)
        #expect(result.finalURL == original)
    }

    @Test("When the https twin answers 404, the URL is retried as given")
    func httpsNotFoundRetriesOriginal() async throws {
        let mock = MockHTTPClient()
        let seen = RequestRecorder()
        let original = try #require(URL(string: "http://feeds.example.org/show"))
        mock.handler = { request in
            seen.record(request)
            if request.url?.scheme == "https" {
                return (Data(), makeHTTPResponse(status: 404))
            }
            return (Data("<rss/>".utf8), makeHTTPResponse(url: original, status: 200))
        }
        let fetcher = FeedFetcher(http: mock)
        let result = try await fetcher.fetch(original, etag: nil, lastModified: nil)
        #expect(seen.requests.count == 2)
        #expect(result.data == Data("<rss/>".utf8))
    }

    @Test("When the retry is refused by App Transport Security, the error says the feed is http-only")
    func retryRefusedByATSIsInsecureFeedUnsupported() async throws {
        let mock = MockHTTPClient()
        let seen = RequestRecorder()
        let original = try #require(URL(string: "http://podcast.example.org/rss"))
        mock.handler = { request in
            seen.record(request)
            if request.url?.scheme == "https" {
                throw URLError(.cannotConnectToHost)
            }
            throw URLError(.appTransportSecurityRequiresSecureConnection)
        }
        let fetcher = FeedFetcher(http: mock)
        do {
            _ = try await fetcher.fetch(original, etag: nil, lastModified: nil)
            Issue.record("Expected insecureFeedUnsupported to be thrown")
        } catch let PodcastsError.insecureFeedUnsupported(feedURL) {
            #expect(feedURL == original)
        }
        #expect(seen.requests.map(\.url?.scheme) == ["https", "http"])
    }

    @Test("A feed over the size cap on https is not retried over http")
    func oversizedHttpsIsNotRetried() async throws {
        let mock = MockHTTPClient()
        let seen = RequestRecorder()
        mock.handler = { request in
            seen.record(request)
            return (Data(count: 100), makeHTTPResponse(status: 200, headers: ["Content-Length": "2000"]))
        }
        let fetcher = FeedFetcher(http: mock, maxBytes: 1024)
        do {
            _ = try await fetcher.fetch(
                #require(URL(string: "http://podcast.example.org/rss")),
                etag: nil, lastModified: nil
            )
            Issue.record("Expected feedTooLarge to be thrown")
        } catch PodcastsError.feedTooLarge {
            // expected
        }
        #expect(seen.requests.count == 1)
    }

    @Test("Loopback plain-http feed URL is fetched as http, with no https attempt")
    func loopbackPlainHttpKept() async throws {
        let mock = MockHTTPClient()
        let seen = RequestRecorder()
        let expectedKept = try #require(URL(string: "http://127.0.0.1:8090/feed"))
        mock.handler = { request in
            seen.record(request)
            return (Data("<rss/>".utf8), makeHTTPResponse(url: expectedKept, status: 200))
        }
        let fetcher = FeedFetcher(http: mock)
        _ = try await fetcher.fetch(expectedKept, etag: nil, lastModified: nil)
        let requested = try #require(seen.requests.last?.url)
        #expect(seen.requests.count == 1)
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
