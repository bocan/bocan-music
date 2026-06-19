import Foundation
import Observability

/// Wraps the Apple iTunes Search API for podcast discovery.
///
/// Keyless: no authentication required. Rows without a `feedUrl` are skipped
/// since they cannot be subscribed to.
public actor ITunesSearchClient {
    private let http: any HTTPClient
    private let log = AppLogger.make(.network)

    public init(http: any HTTPClient = URLSession.shared) {
        self.http = http
    }

    /// Search for podcasts by keyword.
    public func search(
        term: String,
        limit: Int = 40,
        country: String = "US"
    ) async throws -> [PodcastSearchResult] {
        try Task.checkCancellation()
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "country", value: country),
        ]
        let url = comps.url!
        let response: ITunesSearchResponse = try await fetch(url: url)
        return response.results.compactMap { Self.map(result: $0) }
    }

    /// Fetch detail for a single podcast by its iTunes collection ID.
    public func lookup(collectionID: Int) async throws -> PodcastSearchResult? {
        try Task.checkCancellation()
        var comps = URLComponents(string: "https://itunes.apple.com/lookup")!
        comps.queryItems = [URLQueryItem(name: "id", value: String(collectionID))]
        let url = comps.url!
        let response: ITunesSearchResponse = try await fetch(url: url)
        return response.results.compactMap { Self.map(result: $0) }.first
    }

    // MARK: - Networking

    private func fetch<T: Decodable>(url: URL) async throws -> T {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

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
