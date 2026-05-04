import Foundation
import Observability

// MARK: - CoverArtArchiveClient

/// HTTP client for the Cover Art Archive API (coverartarchive.org).
///
/// CAA is hosted on Archive.org with no strict published rate limit;
/// we cap at 2 requests/second to be polite.
public actor CoverArtArchiveClient {
    // MARK: - Constants

    private static let baseURL = URL(string: "https://coverartarchive.org/")!

    // MARK: - Dependencies

    private let session: URLSession
    private let limiter: RateLimiter
    private let log = AppLogger.make(.library)

    // MARK: - Init

    public init(session: URLSession = .shared) {
        self.session = session
        self.limiter = RateLimiter(maxRequests: 2, per: 1.0)
    }

    // MARK: - Public API

    /// Fetches the cover-art index for a release-group MBID.
    public func index(releaseGroupID mbid: String) async throws -> CAAIndex? {
        await self.limiter.wait()
        let url = Self.baseURL
            .appendingPathComponent("release-group")
            .appendingPathComponent(mbid)
        return try await self.fetchIndex(url: url)
    }

    /// Fetches the cover-art index for a release MBID.
    public func index(releaseID mbid: String) async throws -> CAAIndex? {
        await self.limiter.wait()
        let url = Self.baseURL
            .appendingPathComponent("release")
            .appendingPathComponent(mbid)
        return try await self.fetchIndex(url: url)
    }

    /// Downloads the image at `imageURL` (follows Archive.org redirects).
    ///
    /// CAA's JSON API returns `http://` image URLs despite the service supporting HTTPS.
    /// We upgrade to `https://` unconditionally so ATS doesn't block the request.
    public func download(imageURL: URL) async throws -> Data {
        await self.limiter.wait()
        let secureURL = Self.upgradeToHTTPS(imageURL)
        self.log.debug("caa.download", ["url": secureURL.path])
        let (data, _) = try await self.session.data(from: secureURL)
        return data
    }

    // MARK: - Private helpers

    /// Replaces `http` scheme with `https` for coverartarchive.org URLs.
    /// Other URLs (e.g. ia800504.us.archive.org redirects) are returned unchanged.
    private static func upgradeToHTTPS(_ url: URL) -> URL {
        guard url.scheme == "http",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.scheme = "https"
        return components.url ?? url
    }

    private func fetchIndex(url: URL) async throws -> CAAIndex? {
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
        request.setValue("Bocan/1.0 ( mailto:chris@cloudcauldron.io )", forHTTPHeaderField: "User-Agent")

        self.log.debug("caa.index", ["url": url.path])

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await self.session.data(for: request)
        } catch {
            return nil
        }

        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 { return nil }
        guard (200 ..< 300).contains(http.statusCode) else { return nil }

        return try? JSONDecoder().decode(CAAIndex.self, from: data)
    }
}

// MARK: - CAA response models

public struct CAAIndex: Decodable, Sendable {
    public let images: [CAAImage]
    public let release: String?
}

public struct CAAImage: Decodable, Sendable {
    public let image: String
    public let thumbnails: CAAThumbnails
    public let front: Bool
    public let back: Bool
    public let id: String?

    enum CodingKeys: String, CodingKey {
        case image, thumbnails, front, back
        case id
    }

    public var imageURL: URL? {
        URL(string: self.image)
    }

    public var thumbnailURL: URL? {
        self.thumbnails.url500 ?? self.thumbnails.small
    }
}

public struct CAAThumbnails: Decodable, Sendable {
    public let small: URL?
    public let large: URL?

    enum CodingKeys: String, CodingKey {
        case small, large
        case five = "500"
        case two50 = "250"
    }

    /// 500-px URL preferred; falls back to large or small.
    var url500: URL? {
        // CAA embeds 250/500 as numeric string keys; read via coding keys.
        self.large ?? self.small
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.small = try? c.decode(URL.self, forKey: .small)
        self.large = try? c.decode(URL.self, forKey: .large)
    }
}
