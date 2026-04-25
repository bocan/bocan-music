import Foundation
import Observability

// MARK: - AcoustIDClient

/// HTTP client for the AcoustID Web API v2 lookup endpoint.
///
/// Submits a Chromaprint fingerprint and duration, returning a ranked list
/// of identification candidates. Rate-limited to 3 requests/second.
///
/// API key is injected at init time; read it from your app's `Info.plist`
/// key `AcoustIDAPIKey` (populated from `Secrets.xcconfig`).
public actor AcoustIDClient {
    // MARK: - Constants

    private static let baseURL = "https://api.acoustid.org/v2/lookup"

    // MARK: - Dependencies

    private let apiKey: String
    private let httpClient: any HTTPClient
    private let rateLimiter: RateLimiter
    private let log = AppLogger.make(.network)

    // MARK: - Init

    public init(
        apiKey: String,
        rateLimiter: RateLimiter,
        httpClient: (any HTTPClient)? = nil
    ) {
        self.apiKey = apiKey
        self.rateLimiter = rateLimiter
        self.httpClient = httpClient ?? URLSession.shared
    }

    // MARK: - Public API

    /// Looks up the AcoustID fingerprint and returns results sorted by score descending.
    ///
    /// - Parameters:
    ///   - fingerprint: Chromaprint fingerprint string from `fpcalc`.
    ///   - duration: Audio duration in seconds.
    /// - Returns: Array of `AcoustIDResult` sorted by `score` descending (may be empty).
    public func lookup(
        fingerprint: String,
        duration: Int
    ) async throws -> [AcoustIDResult] {
        await self.rateLimiter.wait()

        var components = URLComponents(string: Self.baseURL)!
        components.queryItems = [
            URLQueryItem(name: "client", value: self.apiKey),
            URLQueryItem(name: "meta", value: "recordings+releases+tracks"),
            URLQueryItem(name: "fingerprint", value: fingerprint),
            URLQueryItem(name: "duration", value: String(duration)),
        ]
        guard let url = components.url else {
            throw AcousticsError.invalidResponse(reason: "Could not build AcoustID URL")
        }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        self.log.debug("acoustid.lookup.start", ["duration": duration])

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await self.httpClient.data(for: request)
        } catch {
            throw AcousticsError.networkError(underlying: error)
        }

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 429 {
                throw AcousticsError.rateLimitExceeded
            }
            guard (200 ..< 300).contains(http.statusCode) else {
                throw AcousticsError.invalidResponse(reason: "HTTP \(http.statusCode)")
            }
        }

        let parsed: AcoustIDResponse
        do {
            parsed = try JSONDecoder().decode(AcoustIDResponse.self, from: data)
        } catch {
            throw AcousticsError.invalidResponse(reason: "JSON decode failed: \(error)")
        }

        guard parsed.status == "ok" else {
            throw AcousticsError.invalidResponse(reason: "AcoustID status: \(parsed.status)")
        }

        let sorted = parsed.results.sorted { $0.score > $1.score }
        self.log.debug("acoustid.lookup.done", ["count": sorted.count])
        return sorted
    }
}
