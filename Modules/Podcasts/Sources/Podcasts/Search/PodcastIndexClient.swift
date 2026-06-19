import Foundation
import Observability

/// Wraps the Podcast Index REST API.
///
/// Base URL: `https://api.podcastindex.org/api/1.0`.
/// Every request is signed via ``PodcastIndexAuth`` using the injected credentials.
public actor PodcastIndexClient {
    private let credentials: PodcastIndexCredentials
    private let http: any HTTPClient
    private let now: @Sendable () -> Date
    private let log = AppLogger.make(.network)

    private static let baseURL = "https://api.podcastindex.org/api/1.0"

    public init(
        credentials: PodcastIndexCredentials,
        http: any HTTPClient = URLSession.shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.credentials = credentials
        self.http = http
        self.now = now
    }

    /// Search for podcasts by keyword.
    public func search(term: String, max: Int = 40) async throws -> [PodcastSearchResult] {
        try Task.checkCancellation()
        var comps = URLComponents(string: "\(Self.baseURL)/search/byterm")!
        comps.queryItems = [
            URLQueryItem(name: "q", value: term),
            URLQueryItem(name: "max", value: String(max)),
        ]
        let url = comps.url!
        let response: PISearchResponse = try await fetch(url: url)
        return response.feeds.compactMap { Self.map(feed: $0) }
    }

    /// Fetch rich detail for a single feed URL.
    public func podcast(byFeedURL feedURL: URL) async throws -> PodcastSearchResult? {
        try Task.checkCancellation()
        var comps = URLComponents(string: "\(Self.baseURL)/podcasts/byfeedurl")!
        comps.queryItems = [URLQueryItem(name: "url", value: feedURL.absoluteString)]
        let url = comps.url!
        let response: PIByFeedURLResponse = try await fetch(url: url)
        return Self.map(feed: response.feed)
    }

    // MARK: - Networking

    private func fetch<T: Decodable>(url: URL) async throws -> T {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let authHeaders = PodcastIndexAuth.headers(credentials: self.credentials, now: self.now())
        for (key, value) in authHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        self.log.debug("pi.request.start", ["url": url.absoluteString])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await self.http.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            self.log.error("pi.request.failed", ["url": url.absoluteString, "error": String(reflecting: error)])
            throw PodcastsError.network(underlying: error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PodcastsError.network(underlying: URLError(.badServerResponse))
        }

        let status = httpResponse.statusCode
        self.log.debug("pi.request.end", ["url": url.absoluteString, "status": status])

        if status == 401 || status == 403 {
            throw PodcastsError.searchUnavailable(source: "podcastIndex", reason: "HTTP \(status): check API credentials")
        }
        if status == 429 {
            throw PodcastsError.searchUnavailable(source: "podcastIndex", reason: "rate limited (HTTP 429)")
        }
        guard (200 ..< 300).contains(status) else {
            throw PodcastsError.httpStatus(code: status, url: url)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            self.log.error("pi.decode.failed", ["url": url.absoluteString, "error": String(reflecting: error)])
            throw PodcastsError.parseFailed(url: url, reason: error.localizedDescription)
        }
    }

    private static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        return "Bocan/\(version) Podcast-Reader (+https://cloudcauldron.io/bocan)"
    }()

    // MARK: - Mapping

    private static func map(feed: PIFeed) -> PodcastSearchResult? {
        guard let urlString = feed.url, let feedURL = URL(string: urlString) else { return nil }
        let artwork = (feed.artwork ?? feed.image).flatMap { URL(string: $0) }
        let lastPublished = feed.newestItemPubdate.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let cats = feed.categories.map { Array($0.values).sorted() } ?? []
        return PodcastSearchResult(
            canonicalFeedKey: FeedURL.canonicalKey(feedURL),
            feedURL: feedURL,
            title: feed.title ?? "",
            author: feed.author,
            artworkURL: artwork,
            description: feed.description,
            episodeCount: feed.episodeCount,
            lastPublishedAt: lastPublished,
            categories: cats,
            sources: [.podcastIndex],
            podcastIndexID: feed.id
        )
    }
}

// MARK: - Private DTOs

private struct PISearchResponse: Decodable {
    var feeds: [PIFeed]
}

private struct PIByFeedURLResponse: Decodable {
    var feed: PIFeed
}

private struct PIFeed: Decodable {
    var id: Int?
    var url: String?
    var title: String?
    var author: String?
    var description: String?
    var image: String?
    var artwork: String?
    var link: String?
    var lastUpdateTime: Int?
    var newestItemPubdate: Int?
    var episodeCount: Int?
    var categories: [String: String]?
    var ownerName: String?
    var explicit: Bool?
    var language: String?
}
