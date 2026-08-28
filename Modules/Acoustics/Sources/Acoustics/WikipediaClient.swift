import Foundation
import Observability

// MARK: - WikipediaClient

/// Fetches an artist biography for Deep Dive (#412, #413): a Wikidata item
/// (from MusicBrainz's `wikidata` URL relation) resolves to its English
/// Wikipedia sitelink, whose REST summary supplies the extract, page URL and
/// thumbnail. Text is CC BY-SA; callers must show attribution.
public actor WikipediaClient {
    private static let wikidataBase = "https://www.wikidata.org/wiki/Special:EntityData/"
    private static let summaryBase = "https://en.wikipedia.org/api/rest_v1/page/summary/"

    /// Wikimedia asks for a descriptive User-Agent and modest rates.
    public static let sharedRateLimiter = RateLimiter(maxRequests: 2, per: 1.0)

    private let userAgent: String
    private let httpClient: any HTTPClient
    private let rateLimiter: RateLimiter
    private let log = AppLogger.make(.network)

    public init(
        userAgent: String = UserAgent.string,
        rateLimiter: RateLimiter = WikipediaClient.sharedRateLimiter,
        httpClient: (any HTTPClient)? = nil
    ) {
        self.userAgent = userAgent
        self.rateLimiter = rateLimiter
        self.httpClient = httpClient ?? URLSession.shared
    }

    /// The English Wikipedia summary for a Wikidata item, or nil when the
    /// item has no English article.
    public func summary(wikidataID: String) async throws -> WikipediaSummary? {
        guard let entityURL = URL(string: Self.wikidataBase + wikidataID + ".json") else {
            throw AcousticsError.invalidInput(reason: "Invalid Wikidata id: \(wikidataID)")
        }
        let entity = try await self.get(entityURL, as: WikidataEntityResponse.self, op: "wikidata.entity")
        guard let title = entity.entities[wikidataID]?.sitelinks?["enwiki"]?.title else { return nil }
        return try await self.summary(title: title)
    }

    /// The summary for an English Wikipedia page title.
    public func summary(title: String) async throws -> WikipediaSummary {
        let encoded = title.replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
        guard let url = URL(string: Self.summaryBase + encoded) else {
            throw AcousticsError.invalidInput(reason: "Invalid Wikipedia title: \(title)")
        }
        return try await self.get(url, as: WikipediaSummary.self, op: "wikipedia.summary")
    }

    private func get<T: Decodable>(_ url: URL, as type: T.Type, op: String) async throws -> T {
        try await self.rateLimiter.wait()
        try Task.checkCancellation()
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
        request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        self.log.debug(op, ["url": url.lastPathComponent])
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await self.httpClient.data(for: request)
        } catch {
            throw AcousticsError.networkError(underlying: error)
        }
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw AcousticsError.invalidResponse(reason: "HTTP \(http.statusCode) for \(op)")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AcousticsError.invalidResponse(reason: "\(T.self) decode failed: \(error)")
        }
    }
}

// MARK: - Models

/// `GET /api/rest_v1/page/summary/<title>`.
public struct WikipediaSummary: Decodable, Sendable, Equatable {
    public let title: String
    /// Plain-text lead section.
    public let extract: String
    public let contentURLs: ContentURLs?
    public let thumbnail: Thumbnail?

    public struct ContentURLs: Decodable, Sendable, Equatable {
        public let desktop: Page?

        public struct Page: Decodable, Sendable, Equatable {
            public let page: String
        }
    }

    public struct Thumbnail: Decodable, Sendable, Equatable {
        public let source: String
    }

    enum CodingKeys: String, CodingKey {
        case title, extract, thumbnail
        case contentURLs = "content_urls"
    }

    public var pageURL: URL? {
        self.contentURLs?.desktop.flatMap { URL(string: $0.page) }
    }

    public var thumbnailURL: URL? {
        self.thumbnail.flatMap { URL(string: $0.source) }
    }
}

/// `Special:EntityData/<id>.json`, reduced to the sitelinks we use.
struct WikidataEntityResponse: Decodable {
    let entities: [String: Entity]

    struct Entity: Decodable {
        let sitelinks: [String: Sitelink]?

        struct Sitelink: Decodable {
            let title: String
        }
    }
}
