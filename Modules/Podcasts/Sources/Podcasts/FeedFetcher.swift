import Foundation
import Observability

/// Result of a conditional GET for a feed URL.
public struct FeedFetchResult: Sendable {
    /// The response body, or nil when the server answered 304 Not Modified.
    public var data: Data?
    /// True when the server returned 304 and the locally cached copy is still fresh.
    public var notModified: Bool
    /// ETag validator from the response (for the next conditional GET).
    public var etag: String?
    /// Last-Modified validator from the response (for the next conditional GET).
    public var lastModified: String?
    /// The final URL after following any redirects.
    public var finalURL: URL
}

/// Fetches a feed URL with conditional GET support.
///
/// Does NOT parse; callers pass the `data` to `FeedParser`.
/// Enforces a size cap and respects Task cancellation.
public actor FeedFetcher {
    private let http: any HTTPClient
    private let maxBytes: Int
    private let log = AppLogger.make(.podcasts)

    private static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "Bocan/\(version) Podcast-Reader (+https://cloudcauldron.io/bocan)"
    }()

    public init(http: any HTTPClient = URLSession.shared, maxBytes: Int = 15 * 1024 * 1024) {
        self.http = http
        self.maxBytes = maxBytes
    }

    /// Conditional GET for a feed URL.
    ///
    /// - Parameters:
    ///   - url: The feed URL to fetch.
    ///   - etag: Previously stored ETag validator, if any.
    ///   - lastModified: Previously stored Last-Modified validator, if any.
    /// - Returns: `FeedFetchResult` with either fresh data or `notModified == true`.
    /// - Throws: `PodcastsError.network`, `.httpStatus`, `.feedTooLarge`, or `CancellationError`.
    public func fetch(_ url: URL, etag: String?, lastModified: String?) async throws -> FeedFetchResult {
        try Task.checkCancellation()

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(
            "application/rss+xml, application/atom+xml, application/xml;q=0.9, */*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }

        self.log.debug("feed.fetch.start", ["url": url.absoluteString])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await http.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            self.log.error("feed.fetch.failed", ["url": url.absoluteString, "error": String(reflecting: error)])
            throw PodcastsError.network(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw PodcastsError.network(underlying: URLError(.badServerResponse))
        }

        let finalURL = response.url ?? url

        // 304 Not Modified.
        if http.statusCode == 304 {
            self.log.debug("feed.fetch.notModified", ["url": url.absoluteString])
            return FeedFetchResult(
                data: nil,
                notModified: true,
                etag: http.value(forHTTPHeaderField: "ETag"),
                lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
                finalURL: finalURL
            )
        }

        // Non-2xx responses.
        guard (200 ..< 300).contains(http.statusCode) else {
            self.log.error("feed.fetch.httpError", ["url": url.absoluteString, "status": http.statusCode])
            throw PodcastsError.httpStatus(code: http.statusCode, url: finalURL)
        }

        // Check Content-Length header before using the data.
        if let lengthHeader = http.value(forHTTPHeaderField: "Content-Length"),
           let declared = Int(lengthHeader), declared > maxBytes {
            throw PodcastsError.feedTooLarge(bytes: declared)
        }

        // Guard actual byte count.
        if data.count > self.maxBytes {
            throw PodcastsError.feedTooLarge(bytes: data.count)
        }

        self.log.debug("feed.fetch.end", ["url": url.absoluteString, "bytes": data.count])

        return FeedFetchResult(
            data: data,
            notModified: false,
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
            finalURL: finalURL
        )
    }
}
