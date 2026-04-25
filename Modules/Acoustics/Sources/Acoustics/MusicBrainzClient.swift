import Foundation
import Observability

// MARK: - MusicBrainzClient (Acoustics)

/// HTTP client for MusicBrainz recording lookups.
///
/// Fetches full recording metadata — artist credits, release list, genre tags —
/// by MBID. Rate-limited to 1 request/second per MusicBrainz policy.
///
/// This client is distinct from the one in the Library module (which handles
/// release-group searches for cover art). This one is solely for recording lookups
/// during acoustic identification.
public actor MusicBrainzClient {
    // MARK: - Constants

    private static let baseURL = "https://musicbrainz.org/ws/2/recording/"

    // MARK: - Dependencies

    private let userAgent: String
    private let httpClient: any HTTPClient
    private let rateLimiter: RateLimiter
    private let log = AppLogger.make(.network)

    // MARK: - Init

    /// - Parameters:
    ///   - userAgent: Must follow MusicBrainz policy: `AppName/Version ( contact-url )`.
    ///   - rateLimiter: Shared rate-limiter (1 req/s). **Must** be the same instance
    ///     across all MusicBrainz call sites — sharing is enforced by `FingerprintService`.
    public init(
        userAgent: String,
        rateLimiter: RateLimiter,
        httpClient: (any HTTPClient)? = nil
    ) {
        self.userAgent = userAgent
        self.rateLimiter = rateLimiter
        self.httpClient = httpClient ?? URLSession.shared
    }

    // MARK: - Public API

    /// Fetches a full recording by MusicBrainz recording MBID.
    ///
    /// Includes releases, artists, and tags (`?inc=releases+artists+tags`).
    public func fetchRecording(mbid: String) async throws -> MBRecording {
        await self.rateLimiter.wait()

        let urlString = Self.baseURL + mbid + "?inc=releases+artists+tags&fmt=json"
        guard let url = URL(string: urlString) else {
            throw AcousticsError.invalidResponse(reason: "Invalid MBID: \(mbid)")
        }

        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
        request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        self.log.debug("mb.recording.fetch", ["mbid": mbid])

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await self.httpClient.data(for: request)
        } catch {
            throw AcousticsError.networkError(underlying: error)
        }

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 503 {
                // MusicBrainz uses 503 for rate-limit errors, not 429.
                throw AcousticsError.rateLimitExceeded
            }
            guard (200 ..< 300).contains(http.statusCode) else {
                throw AcousticsError.invalidResponse(reason: "HTTP \(http.statusCode) for MBID \(mbid)")
            }
        }

        do {
            return try JSONDecoder().decode(MBRecording.self, from: data)
        } catch {
            throw AcousticsError.invalidResponse(reason: "MBRecording decode failed: \(error)")
        }
    }
}
