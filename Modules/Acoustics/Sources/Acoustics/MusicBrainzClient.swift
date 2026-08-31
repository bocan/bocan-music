import Foundation
import Observability

// MARK: - MusicBrainzClient

/// The one HTTP client for the MusicBrainz Web Service 2 (issue #412).
///
/// Every MusicBrainz call in the app goes through an instance of this actor
/// and, by default, through `sharedRateLimiter`, so the 1 request/second
/// policy the `User-Agent` string commits us to holds across identify,
/// cover-art search and Deep Dive at once. Tests inject a permissive limiter
/// and a stub `HTTPClient`.
public actor MusicBrainzClient {
    // MARK: - Constants

    private static let baseURL = URL(string: "https://musicbrainz.org/ws/2/")!

    /// Process-wide 1 req/s budget shared by every MusicBrainz caller.
    public static let sharedRateLimiter = RateLimiter(maxRequests: 1, per: 1.0)

    // MARK: - Dependencies

    private let userAgent: String
    private let httpClient: any HTTPClient
    private let rateLimiter: RateLimiter
    private let log = AppLogger.make(.network)

    // MARK: - Init

    /// - Parameters:
    ///   - userAgent: Must follow MusicBrainz policy: `AppName/Version ( contact-url )`.
    ///   - rateLimiter: Defaults to `sharedRateLimiter`; pass another only in tests.
    public init(
        userAgent: String = UserAgent.string,
        rateLimiter: RateLimiter = MusicBrainzClient.sharedRateLimiter,
        httpClient: (any HTTPClient)? = nil
    ) {
        self.userAgent = userAgent
        self.rateLimiter = rateLimiter
        self.httpClient = httpClient ?? URLSession.shared
    }

    // MARK: - Recordings

    /// Fetches a full recording by MBID: releases (with release-groups and
    /// media), artists, tags and ISRCs in one request. Never page or fan out
    /// per release; the 1 req/s budget is shared with every other call site.
    ///
    /// `labels` is not a valid inc on the recording resource, so candidates
    /// carry no label data; that needs `/release/<id>?inc=labels`.
    public func fetchRecording(mbid: String) async throws -> MBRecording {
        try await self.get(
            "recording/\(mbid)",
            query: ["inc": "releases+release-groups+artists+tags+isrcs+media+work-rels"],
            as: MBRecording.self,
            op: "mb.recording.fetch",
            context: mbid
        )
    }

    // MARK: - Releases

    /// Fetches one release with its labels, media and release group, for the
    /// album Deep Dive (#413).
    public func fetchRelease(mbid: String) async throws -> MBRelease {
        try await self.get(
            "release/\(mbid)",
            query: ["inc": "labels+media+release-groups+artist-credits"],
            as: MBRelease.self,
            op: "mb.release.fetch",
            context: mbid
        )
    }

    /// Fetches a release group with its releases, to pick a representative
    /// release when an album carries only a release-group id.
    public func fetchReleaseGroup(mbid: String) async throws -> MBReleaseGroup {
        try await self.get(
            "release-group/\(mbid)",
            query: ["inc": "releases+artist-credits"],
            as: MBReleaseGroup.self,
            op: "mb.release-group.fetch",
            context: mbid
        )
    }

    // MARK: - Works

    /// Fetches a work with its writer relations (composer, lyricist).
    public func fetchWork(mbid: String) async throws -> MBWork {
        try await self.get(
            "work/\(mbid)",
            query: ["inc": "artist-rels"],
            as: MBWork.self,
            op: "mb.work.fetch",
            context: mbid
        )
    }

    // MARK: - Release groups

    /// Searches release-groups matching `artist` + `album` (cover-art lookup).
    public func searchReleaseGroups(artist: String, album: String, limit: Int = 10) async throws -> [MBReleaseGroup] {
        let query = "artist:\"\(artist.mbEscaped)\" AND releasegroup:\"\(album.mbEscaped)\""
        return try await self.get(
            "release-group",
            query: ["query": query, "limit": String(limit)],
            as: MBReleaseGroupSearchResponse.self,
            op: "mb.release-group.search",
            context: album
        ).releaseGroups
    }

    /// Searches recordings by artist + title, best score first, for guessing
    /// a recording MBID the tags did not supply (Deep Dive).
    public func searchRecordings(artist: String, title: String, limit: Int = 10) async throws -> [MBRecordingSearchResult] {
        let query = "artist:\"\(artist.mbEscaped)\" AND recording:\"\(title.mbEscaped)\""
        return try await self.get(
            "recording",
            query: ["query": query, "limit": String(limit)],
            as: MBRecordingSearchResponse.self,
            op: "mb.recording.search",
            context: title
        ).recordings
    }

    /// Browses an artist's release groups (their discography); page with `offset`.
    public func browseReleaseGroups(artistMBID: String, limit: Int = 100, offset: Int = 0) async throws -> MBReleaseGroupBrowse {
        try await self.get(
            "release-group",
            query: ["artist": artistMBID, "limit": String(limit), "offset": String(offset), "inc": "artist-credits"],
            as: MBReleaseGroupBrowse.self,
            op: "mb.release-group.browse",
            context: artistMBID
        )
    }

    // MARK: - Artists

    /// Fetches an artist with its URL relations (Wikidata, Discogs, homepage)
    /// and artist relations (band members with dates), for Deep Dive.
    public func fetchArtist(mbid: String) async throws -> MBArtistDetail {
        try await self.get(
            "artist/\(mbid)",
            query: ["inc": "url-rels+artist-rels+aliases"],
            as: MBArtistDetail.self,
            op: "mb.artist.fetch",
            context: mbid
        )
    }

    /// Searches artists by name, best score first, for guessing an MBID the
    /// tags did not supply.
    public func searchArtists(name: String, limit: Int = 10) async throws -> [MBArtistSearchResult] {
        try await self.get(
            "artist",
            query: ["query": "artist:\"\(name.mbEscaped)\"", "limit": String(limit)],
            as: MBArtistSearchResponse.self,
            op: "mb.artist.search",
            context: name
        ).artists
    }

    // MARK: - Transport

    private func get<T: Decodable>(
        _ path: String,
        query: [String: String],
        as type: T.Type,
        op: String,
        context: String
    ) async throws -> T {
        try await self.rateLimiter.wait()
        // The slot may have been granted after this job was cancelled; never
        // fire a request for a cancelled fetch (#273).
        try Task.checkCancellation()

        var comps = URLComponents(url: Self.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        var items = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "fmt", value: "json"))
        comps?.queryItems = items
        guard let url = comps?.url else {
            throw AcousticsError.invalidResponse(reason: "Invalid MusicBrainz request: \(path)")
        }

        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
        request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        self.log.debug(op, ["context": context])

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
                throw AcousticsError.invalidResponse(reason: "HTTP \(http.statusCode) for \(op) \(context)")
            }
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AcousticsError.invalidResponse(reason: "\(T.self) decode failed: \(error)")
        }
    }
}

// MARK: - Lucene escaping

extension String {
    /// Escapes the characters that would otherwise be read as Lucene syntax
    /// inside a quoted MusicBrainz search term.
    var mbEscaped: String {
        self.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
