import Foundation
import Observability

// MARK: - MusicBrainzClient

/// HTTP client for the MusicBrainz Web Service 2 API.
///
/// Rate-limited to 1 request/second per MusicBrainz policy.
/// User-Agent is required; missing it results in 403.
public actor MusicBrainzClient {
    // MARK: - Constants

    private static let baseURL = URL(string: "https://musicbrainz.org/ws/2/")!
    /// User-Agent required by MusicBrainz: Name/Version (Contact)
    private static let userAgent = "Bocan/1.0 ( mailto:chris@cloudcauldron.io )"

    // MARK: - Dependencies

    private let session: URLSession
    private let limiter: RateLimiter
    private let log = AppLogger.make(.library)

    // MARK: - Init

    public init(session: URLSession = .shared) {
        self.session = session
        self.limiter = RateLimiter(maxRequests: 1, per: 1.0)
    }

    // MARK: - Public API

    /// Searches for release-groups matching `artist` + `album`.
    ///
    /// Returns up to `limit` results. Tries release-group first for better
    /// cross-pressing matching.
    public func searchReleaseGroups(
        artist: String,
        album: String,
        limit: Int = 10
    ) async throws -> [MBReleaseGroup] {
        await self.limiter.wait()

        let query = "artist:\"\(artist.mbEscaped)\" AND releasegroup:\"\(album.mbEscaped)\""
        var comps = URLComponents(url: Self.baseURL.appendingPathComponent("release-group"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "fmt", value: "json"),
        ]
        guard let url = comps.url else { return [] }

        let data = try await self.fetch(url: url)
        let response = try JSONDecoder().decode(MBReleaseGroupSearchResponse.self, from: data)
        return response.releaseGroups
    }

    // MARK: - Private helpers

    private func fetch(url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        self.log.debug("mb.request", ["url": url.path])

        let (data, response) = try await self.session.data(for: request)

        if let http = response as? HTTPURLResponse {
            // Honour Retry-After when rate-limited by the server.
            if http.statusCode == 503,
               let retryAfter = http.value(forHTTPHeaderField: "Retry-After"),
               let seconds = Double(retryAfter) {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return try await self.fetch(url: url)
            }
            guard (200 ..< 300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
        }
        return data
    }
}

// MARK: - MusicBrainz response models

public struct MBReleaseGroupSearchResponse: Decodable {
    public let releaseGroups: [MBReleaseGroup]

    enum CodingKeys: String, CodingKey {
        case releaseGroups = "release-groups"
    }
}

public struct MBReleaseGroup: Decodable, Sendable {
    public let id: String
    public let title: String
    public let artistCredit: [MBArtistCredit]?
    public let firstReleaseDate: String?
    public let releases: [MBRelease]?

    enum CodingKeys: String, CodingKey {
        case id, title, releases
        case artistCredit = "artist-credit"
        case firstReleaseDate = "first-release-date"
    }

    public var artistName: String {
        self.artistCredit?.compactMap { $0.name ?? $0.artist?.name }.joined() ?? ""
    }

    public var year: Int? {
        guard let d = self.firstReleaseDate, d.count >= 4 else { return nil }
        return Int(d.prefix(4))
    }
}

public struct MBArtistCredit: Decodable, Sendable {
    public let name: String?
    public let joinphrase: String?
    public let artist: MBArtist?
}

public struct MBArtist: Decodable, Sendable {
    public let id: String
    public let name: String
}

public struct MBRelease: Decodable, Sendable {
    public let id: String
    public let title: String
}

// MARK: - String extension

private extension String {
    /// Escapes special Lucene/MB query characters.
    var mbEscaped: String {
        self.replacingOccurrences(of: "\"", with: "\\\"")
    }
}
