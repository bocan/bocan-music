import Foundation
import Metadata
import Observability

// MARK: - LRClibClientProtocol

/// Abstraction over the LRClib HTTP API, allowing test doubles to be injected.
public protocol LRClibClientProtocol: Sendable {
    /// Fetches lyrics using an exact artist/title/album/duration lookup.
    ///
    /// Returns `nil` when no match is found or when the request fails gracefully.
    func get(
        artist: String,
        title: String,
        album: String?,
        duration: TimeInterval
    ) async throws -> LyricsDocument?

    /// Searches LRClib with optional filters.
    ///
    /// Returns an empty array on failure rather than throwing,
    /// so callers can fall through to the next source without crashing.
    func search(
        artist: String?,
        title: String?,
        album: String?
    ) async throws -> [LyricsDocument]
}

// MARK: - LRClibClient

/// HTTP client for `https://lrclib.net/api/`.
///
/// Must be opt-in via Settings.  Never called without user consent.
public actor LRClibClient: LRClibClientProtocol {
    // MARK: - Constants

    private static let baseURL = URL(string: "https://lrclib.net/api/")!
    private static let userAgent = "Bocan/1.0 (https://github.com/bocan-music; mailto:chris@cloudcauldron.io)"

    // MARK: - Dependencies

    private let session: URLSession
    private let limiter: RateLimiter
    private let log = AppLogger.make(.network)

    // MARK: - Init

    public init(session: URLSession = .shared) {
        self.session = session
        self.limiter = RateLimiter(maxRequests: 1, per: 1.0)
    }

    // MARK: - LRClibClientProtocol

    public func get(
        artist: String,
        title: String,
        album: String?,
        duration: TimeInterval
    ) async throws -> LyricsDocument? {
        await self.limiter.wait()

        var components = URLComponents(url: Self.baseURL.appendingPathComponent("get"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "duration", value: String(Int(duration))),
        ]
        if let album {
            items.append(URLQueryItem(name: "album_name", value: album))
        }
        components.queryItems = items

        guard let url = components.url else { return nil }

        self.log.debug("lrclib.get.start", ["artist": artist, "title": title])

        return try await self.fetchWithRetry(url: url)
    }

    public func search(
        artist: String?,
        title: String?,
        album: String?
    ) async throws -> [LyricsDocument] {
        await self.limiter.wait()

        var components = URLComponents(url: Self.baseURL.appendingPathComponent("search"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = []
        if let artist { items.append(URLQueryItem(name: "artist_name", value: artist)) }
        if let title { items.append(URLQueryItem(name: "track_name", value: title)) }
        if let album { items.append(URLQueryItem(name: "album_name", value: album)) }
        components.queryItems = items

        guard let url = components.url else { return [] }

        self.log.debug("lrclib.search.start", ["artist": artist ?? "", "title": title ?? ""])

        let request = self.makeRequest(url: url)
        guard let data = try await self.fetchData(for: request) else { return [] }

        let results = (try? JSONDecoder().decode([LRClibSearchResult].self, from: data)) ?? []
        return results.compactMap { Self.toDocument($0) }
    }

    // MARK: - Private

    private func fetchWithRetry(url: URL) async throws -> LyricsDocument? {
        let maxAttempts = 3
        var attempt = 0

        while attempt < maxAttempts {
            try Task.checkCancellation()
            let request = self.makeRequest(url: url)

            do {
                let (data, response) = try await self.session.data(for: request)
                guard let http = response as? HTTPURLResponse else { return nil }

                switch http.statusCode {
                case 200:
                    guard let result = try? JSONDecoder().decode(LRClibGetResult.self, from: data) else { return nil }
                    return Self.toDocument(result)
                case 404:
                    return nil
                case 429:
                    attempt += 1
                    let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                    self.log.warning("lrclib.rateLimit", ["attempt": attempt])
                    try await Task.sleep(nanoseconds: delay)
                default:
                    self.log.warning("lrclib.unexpectedStatus", ["status": http.statusCode])
                    return nil
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                self.log.error("lrclib.networkError", ["error": String(reflecting: error)])
                return nil
            }
        }
        return nil
    }

    private func fetchData(for request: URLRequest) async throws -> Data? {
        do {
            let (data, response) = try await self.session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200 ..< 300).contains(http.statusCode) else { return nil }
            return data
        } catch {
            self.log.error("lrclib.fetchFailed", ["error": String(reflecting: error)])
            return nil
        }
    }

    private func makeRequest(url: URL) -> URLRequest {
        var req = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return req
    }

    private static func toDocument(_ result: some LRClibResult) -> LyricsDocument? {
        if let synced = result.syncedLyrics, !synced.isEmpty {
            return LRCParser.parseDocument(synced)
        }
        if let plain = result.plainLyrics, !plain.isEmpty {
            return .unsynced(plain)
        }
        return nil
    }
}

// MARK: - Response models

private protocol LRClibResult {
    var syncedLyrics: String? { get }
    var plainLyrics: String? { get }
}

private struct LRClibGetResult: Decodable, LRClibResult {
    let syncedLyrics: String?
    let plainLyrics: String?

    enum CodingKeys: String, CodingKey {
        case syncedLyrics
        case plainLyrics
    }
}

private struct LRClibSearchResult: Decodable, LRClibResult {
    let syncedLyrics: String?
    let plainLyrics: String?

    enum CodingKeys: String, CodingKey {
        case syncedLyrics
        case plainLyrics
    }
}
