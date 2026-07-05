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
    /// Includes releases (with their release-groups and media), artists, tags, and
    /// ISRCs. One request, bigger response — never page or fan out per release; the
    /// 1 req/s budget is shared with every other MusicBrainz call site.
    ///
    /// Note: `labels` is NOT a valid inc parameter on the recording resource (the
    /// API rejects the whole request), which is why candidates carry no label data.
    /// Label/catalog-number would need a per-release lookup (`/release/<id>?inc=labels`).
    public func fetchRecording(mbid: String) async throws -> MBRecording {
        try await self.rateLimiter.wait()
        // The slot may have been granted after this job was cancelled (or the
        // job may have been cancelled while waiting in line). Bail before
        // firing the request so a cancelled fetch never hits the network. See #273.
        try Task.checkCancellation()

        let urlString = Self.baseURL + mbid + "?inc=releases+release-groups+artists+tags+isrcs+media&fmt=json"
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
