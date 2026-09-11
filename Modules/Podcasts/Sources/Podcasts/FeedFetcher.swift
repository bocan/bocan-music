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

    public init(http: any HTTPClient = URLSession.shared, maxBytes: Int = 50 * 1024 * 1024) {
        self.http = http
        self.maxBytes = maxBytes
    }

    /// Conditional GET for a feed URL.
    ///
    /// Plain-http feed URLs are upgraded to https before the request unless the
    /// host is loopback (local dev feeds, E2E fixtures). App Transport Security
    /// blocks plain http on real hosts, and iTunes/Podcast Index search rows
    /// still return http-only `feedUrl`s for older podcasts. The https variant
    /// of such feeds serves identical content and validators, so stored etags
    /// and Last-Modified stamps stay consistent.
    ///
    /// - Parameters:
    ///   - url: The feed URL to fetch.
    ///   - etag: Previously stored ETag validator, if any.
    ///   - lastModified: Previously stored Last-Modified validator, if any.
    /// - Returns: `FeedFetchResult` with either fresh data or `notModified == true`.
    /// - Throws: `PodcastsError.network`, `.httpStatus`, `.feedTooLarge`, or `CancellationError`.
    public func fetch(_ url: URL, etag: String?, lastModified: String?) async throws -> FeedFetchResult {
        try Task.checkCancellation()

        let fetchURL = Self.httpsUpgraded(url)
        if fetchURL != url {
            self.log.debug("feed.fetch.schemeUpgraded", [
                "from": url.absoluteString,
                "to": fetchURL.absoluteString,
            ])
        }

        var request = URLRequest(url: fetchURL, timeoutInterval: 20)
        request.setValue(UserAgent.string, forHTTPHeaderField: "User-Agent")
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

        self.log.debug("feed.fetch.start", ["url": fetchURL.absoluteString])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await http.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            self.log.error("feed.fetch.failed", ["url": fetchURL.absoluteString, "error": String(reflecting: error)])
            throw PodcastsError.network(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw PodcastsError.network(underlying: URLError(.badServerResponse))
        }

        let finalURL = response.url ?? fetchURL

        // 304 Not Modified.
        if http.statusCode == 304 {
            self.log.debug("feed.fetch.notModified", ["url": fetchURL.absoluteString])
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
            self.log.error("feed.fetch.httpError", ["url": fetchURL.absoluteString, "status": http.statusCode])
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

        self.log.debug("feed.fetch.end", ["url": fetchURL.absoluteString, "bytes": data.count])

        return FeedFetchResult(
            data: data,
            notModified: false,
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified"),
            finalURL: finalURL
        )
    }

    /// Upgrades a plain-http feed URL to https, except loopback hosts.
    /// Returns the input URL unchanged for non-http schemes or loopback.
    static func httpsUpgraded(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "http",
              !FeedURL.isLoopback(host: components.host) else {
            return url
        }
        components.scheme = "https"
        return components.url ?? url
    }
}
