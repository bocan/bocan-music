import Foundation
import Observability

/// Fetches and parses a Podcasting 2.0 JSON chapters document on demand.
///
/// Mirrors `FeedFetcher`: shared `User-Agent`, a short timeout, a size cap, and
/// http/https only. Errors are thrown but the caller degrades them to "no
/// chapters". An in-memory cache keyed by URL avoids re-fetching the same
/// document within a session. The durable cache is `podcast_episode_chapters`,
/// which `PodcastService` fills from the body `fetch(_:)` hands back (#608).
public actor ChaptersFetcher {
    private let http: any HTTPClient
    private let maxBytes: Int
    private let log = AppLogger.make(.podcasts)
    private var cache: [URL: [Chapter]] = [:]

    /// Creates a fetcher with an empty in-memory cache. `maxBytes` is the
    /// size cap for a chapters document, 1 MB by default.
    public init(http: any HTTPClient = URLSession.shared, maxBytes: Int = 1024 * 1024) {
        self.http = http
        self.maxBytes = maxBytes
    }

    /// The result of `fetch(_:)`: the parsed chapters, plus the raw document
    /// when this call downloaded it. `body` is `nil` on an in-memory cache hit,
    /// so a caller that persists the document does so once per download.
    public struct Fetched: Sendable {
        public let chapters: [Chapter]
        public let body: Data?
    }

    /// Returns the parsed, start-sorted chapters for `url`, cached after the first
    /// fetch. Throws `PodcastsError` on a bad URL, network error, non-2xx, or an
    /// oversized body; an unparseable body yields an empty list (not a throw).
    public func chapters(for url: URL) async throws -> [Chapter] {
        try await self.fetch(url).chapters
    }

    /// `chapters(for:)`, also handing back the document as served when this
    /// call went to the network.
    public func fetch(_ url: URL) async throws -> Fetched {
        if let cached = self.cache[url] {
            return Fetched(chapters: cached, body: nil)
        }
        try Task.checkCancellation()

        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw PodcastsError.invalidFeedURL(url.absoluteString)
        }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(UserAgent.string, forHTTPHeaderField: "User-Agent")
        self.log.debug("chapters.fetch.start", ["url": url.absoluteString])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await self.http.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            self.log.error(
                "chapters.fetch.failed",
                ["url": url.absoluteString, "error": String(reflecting: error)]
            )
            throw PodcastsError.network(underlying: error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw PodcastsError.network(underlying: URLError(.badServerResponse))
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw PodcastsError.httpStatus(code: http.statusCode, url: url)
        }
        if data.count > self.maxBytes {
            throw PodcastsError.feedTooLarge(bytes: data.count)
        }

        let chapters = Self.parse(data)
        self.cache[url] = chapters
        self.log.debug("chapters.fetch.end", ["url": url.absoluteString, "count": chapters.count])
        return Fetched(chapters: chapters, body: data)
    }

    /// Parses the Podcasting 2.0 JSON chapters document. Entries without a
    /// `startTime` are skipped; an unparseable body or missing `chapters` array
    /// yields an empty list. Sorted ascending by start time, `id` = sorted index.
    public static func parse(_ data: Data) -> [Chapter] {
        guard let document = try? JSONDecoder().decode(ChaptersDocument.self, from: data),
              let entries = document.chapters else {
            return []
        }
        let valid = entries
            .filter { $0.startTime != nil }
            .sorted { ($0.startTime ?? 0) < ($1.startTime ?? 0) }
        return valid.enumerated().map { index, entry in
            Chapter(
                id: index,
                startTime: entry.startTime ?? 0,
                title: entry.title ?? "",
                imageURL: entry.img.flatMap { URL(string: $0) },
                url: entry.url.flatMap { URL(string: $0) }
            )
        }
    }
}

// MARK: - JSON shape (Podcasting 2.0 chapters)

private struct ChaptersDocument: Decodable {
    let chapters: [ChaptersEntry]?
}

private struct ChaptersEntry: Decodable {
    let startTime: Double?
    let title: String?
    let img: String?
    let url: String?
}
