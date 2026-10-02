import Foundation
import Observability

/// Wraps the Apple iTunes Search API for podcast discovery.
///
/// Keyless: no authentication required. Rows without a `feedUrl` are skipped
/// since they cannot be subscribed to.
public actor ITunesSearchClient {
    private let http: any HTTPClient
    private let log = AppLogger.make(.network)

    /// Creates a client. `http` is the network seam for tests.
    public init(http: any HTTPClient = URLSession.shared) {
        self.http = http
    }

    /// Search for podcasts by keyword in one country's Apple Podcasts
    /// catalogue (`country` is an ISO 3166-1 alpha-2 code).
    public func search(
        term: String,
        limit: Int = 40,
        country: String = PodcastSettings.defaultStorefront
    ) async throws -> [PodcastSearchResult] {
        try Task.checkCancellation()
        let url = try Self.requestURL(path: "search", queryItems: [
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "country", value: country),
        ])
        let response: ITunesSearchResponse = try await fetch(url: url)
        return response.results.compactMap { Self.map(result: $0) }
    }

    /// Fetch detail for a single podcast by its iTunes collection ID, from the
    /// same storefront the search used (a show can be missing from another).
    public func lookup(
        collectionID: Int,
        country: String = PodcastSettings.defaultStorefront
    ) async throws -> PodcastSearchResult? {
        try Task.checkCancellation()
        let url = try Self.requestURL(path: "lookup", queryItems: [
            URLQueryItem(name: "id", value: String(collectionID)),
            URLQueryItem(name: "country", value: country),
        ])
        let response: ITunesSearchResponse = try await fetch(url: url)
        return response.results.compactMap { Self.map(result: $0) }.first
    }

    // MARK: - Networking

    /// Builds the request URL for `path` on the iTunes host. The host and the
    /// path are constants and `URLComponents` percent-encodes the query, so a
    /// failure here means the endpoint itself is malformed; the caller gets
    /// the same error as for any other failure of this source.
    private static func requestURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        let endpoint = "https://itunes.apple.com/\(path)"
        guard var comps = URLComponents(string: endpoint) else {
            throw PodcastsError.searchUnavailable(source: "itunes", reason: "invalid request URL: \(endpoint)")
        }
        comps.queryItems = queryItems
        guard let url = comps.url else {
            throw PodcastsError.searchUnavailable(source: "itunes", reason: "invalid request URL: \(endpoint)")
        }
        return url
    }

    private func fetch<T: Decodable>(url: URL) async throws -> T {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(UserAgent.string, forHTTPHeaderField: "User-Agent")

        self.log.debug("itunes.request.start", ["url": url.absoluteString])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await self.http.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            self.log.error("itunes.request.failed", ["url": url.absoluteString, "error": String(reflecting: error)])
            throw PodcastsError.network(underlying: error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PodcastsError.network(underlying: URLError(.badServerResponse))
        }

        let status = httpResponse.statusCode
        self.log.debug("itunes.request.end", ["url": url.absoluteString, "status": status])

        guard (200 ..< 300).contains(status) else {
            throw PodcastsError.httpStatus(code: status, url: url)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            self.log.error("itunes.decode.failed", ["url": url.absoluteString, "error": String(reflecting: error)])
            throw PodcastsError.parseFailed(url: url, reason: error.localizedDescription)
        }
    }

    // MARK: - Mapping

    private static func map(result: ITunesResult) -> PodcastSearchResult? {
        // Skip rows without a subscribable feed URL.
        guard let feedURLString = result.feedUrl, let feedURL = URL(string: feedURLString) else {
            return nil
        }
        // Prefer the largest available artwork.
        let artworkURLString = result.artworkUrl600 ?? result.artworkUrl100 ?? result.artworkUrl60
        let artworkURL = artworkURLString.flatMap { URL(string: $0) }
        let title = result.collectionName ?? result.trackName ?? ""
        return PodcastSearchResult(
            canonicalFeedKey: FeedURL.canonicalKey(feedURL),
            feedURL: feedURL,
            title: title,
            author: result.artistName,
            artworkURL: artworkURL,
            description: nil,
            episodeCount: result.trackCount,
            lastPublishedAt: nil,
            categories: result.genres ?? [],
            sources: [.itunes],
            podcastIndexID: nil,
            itunesCollectionID: result.collectionId
        )
    }
}

// MARK: - Private DTOs

private struct ITunesSearchResponse: Decodable {
    var resultCount: Int
    var results: [ITunesResult]
}

private struct ITunesResult: Decodable {
    var collectionId: Int?
    var artistName: String?
    var collectionName: String?
    var trackName: String?
    var feedUrl: String?
    var artworkUrl60: String?
    var artworkUrl100: String?
    var artworkUrl600: String?
    var genres: [String]?
    var trackCount: Int?
}
