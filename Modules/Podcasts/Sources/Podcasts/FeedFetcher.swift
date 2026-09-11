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
    /// A plain-http URL is tried over https first: App Transport Security
    /// refuses plain http to internet hosts, and the directories still list
    /// http-only `feedUrl`s for older shows whose https twin serves the same
    /// feed and validators. If the https attempt fails with a network or HTTP
    /// error, the URL is retried exactly as given and ATS decides: it lets
    /// plain http through to the local network and loopback, and refuses it
    /// for internet hosts, which surfaces as `insecureFeedUnsupported`.
    /// Loopback hosts skip the https attempt (E2E fixtures, a local dev feed).
    ///
    /// - Parameters:
    ///   - url: The feed URL to fetch.
    ///   - etag: Previously stored ETag validator, if any.
    ///   - lastModified: Previously stored Last-Modified validator, if any.
    /// - Returns: `FeedFetchResult` with either fresh data or `notModified == true`.
    /// - Throws: `PodcastsError.network`, `.httpStatus`, `.feedTooLarge`,
    ///   `.insecureFeedUnsupported`, or `CancellationError`.
    public func fetch(_ url: URL, etag: String?, lastModified: String?) async throws -> FeedFetchResult {
        try Task.checkCancellation()

        let upgraded = Self.httpsUpgraded(url)
        guard upgraded != url else {
            return try await self.perform(url, etag: etag, lastModified: lastModified)
        }

        self.log.debug("feed.fetch.schemeUpgraded", ["from": url.absoluteString, "to": upgraded.absoluteString])
        do {
            return try await self.perform(upgraded, etag: etag, lastModified: lastModified)
        } catch let error as PodcastsError {
            switch error {
            case .network, .httpStatus:
                // The secure twin does not serve this feed. Try the URL as
                // given; a larger-than-cap feed is not retried, it would only
                // download the same bytes again.
                self.log.debug("feed.fetch.retryOriginal", [
                    "url": url.absoluteString,
                    "httpsError": String(reflecting: error),
                ])

            default:
                throw error
            }
        }

        do {
            return try await self.perform(url, etag: etag, lastModified: lastModified)
        } catch let PodcastsError.network(underlying)
            where (underlying as? URLError)?.code == .appTransportSecurityRequiresSecureConnection {
            self.log.warning("feed.fetch.insecureOnly", ["url": url.absoluteString])
            throw PodcastsError.insecureFeedUnsupported(feedURL: url)
        }
    }

    /// One conditional GET of exactly `url`, no scheme rewriting.
    private func perform(_ url: URL, etag: String?, lastModified: String?) async throws -> FeedFetchResult {
        var request = URLRequest(url: url, timeoutInterval: 20)
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

    /// The https twin of a plain-http feed URL, or the URL unchanged for any
    /// other scheme and for loopback hosts.
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
