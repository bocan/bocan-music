import Foundation
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
}
