import Foundation
import Observability
import Persistence

// MARK: - CoverArtSearchService

/// Combines `MusicBrainzClient` + `CoverArtArchiveClient` into a single
/// search → candidates flow.
///
/// Strategy:
/// 1. Search MusicBrainz for release-groups matching artist + album.
/// 2. For each release-group, fetch the Cover Art Archive index.
/// 3. Build `CoverArtCandidate` values from front-cover images.
///
/// Results are cached in memory for `cacheDuration` (default: 24 h).
/// Thumbnail data is cached on disk in `<AppSupport>/Bocan/CoverArtCache/Fetch/`.
public actor CoverArtSearchService: CoverArtFetcher {
    // MARK: - Dependencies

    private let mbClient: MusicBrainzClient
    private let caaClient: CoverArtArchiveClient
    private let diskCache: FetchThumbnailCache
    private let log = AppLogger.make(.library)

    // MARK: - In-memory search result cache

    private struct CacheEntry {
        let candidates: [CoverArtCandidate]
        let expiresAt: Date
    }

    private var searchCache: [String: CacheEntry] = [:]
    private let cacheDuration: TimeInterval

    // MARK: - Init

    public init(
        mbClient: MusicBrainzClient = MusicBrainzClient(),
        caaClient: CoverArtArchiveClient = CoverArtArchiveClient(),
        cacheDuration: TimeInterval = 86400
    ) {
        self.mbClient = mbClient
        self.caaClient = caaClient
        self.diskCache = FetchThumbnailCache()
        self.cacheDuration = cacheDuration
    }

    // MARK: - CoverArtFetcher

    public func search(artist: String, album: String) async throws -> [CoverArtCandidate] {
        let key = "\(artist)||||\(album)"
        if let entry = self.searchCache[key], entry.expiresAt > Date() {
            return entry.candidates
        }

        self.log.debug("coverart.search", ["artist": artist, "album": album])

        let groups = try await self.mbClient.searchReleaseGroups(artist: artist, album: album)

        var candidates: [CoverArtCandidate] = []
        for group in groups.prefix(5) {
            try Task.checkCancellation()
            if let index = try? await self.caaClient.index(releaseGroupID: group.id) {
                let frontImages = index.images.filter(\.front)
                for img in frontImages.prefix(1) {
                    guard let thumbURL = img.thumbnailURL, let fullURL = img.imageURL else { continue }
                    let candidate = CoverArtCandidate(
                        id: group.id + (img.id ?? ""),
                        releaseGroupID: group.id,
                        releaseID: nil,
                        title: group.title,
                        artist: group.artistName,
                        year: group.year,
                        thumbnailURL: thumbURL,
                        fullURL: fullURL,
                        source: .coverArtArchive
                    )
                    candidates.append(candidate)
                }
            }
        }

        self.searchCache[key] = CacheEntry(
            candidates: candidates,
            expiresAt: Date().addingTimeInterval(self.cacheDuration)
        )
        self.log.debug("coverart.search.done", ["count": candidates.count])
        return candidates
    }

    public func image(for candidate: CoverArtCandidate, size: CoverArtSize) async throws -> Data {
        let url = size == .thumbnail ? candidate.thumbnailURL : candidate.fullURL
        let cacheKey = candidate.id + (size == .thumbnail ? "-thumb" : "-full")

        if let cached = await self.diskCache.load(key: cacheKey) {
            return cached
        }

        let data = try await self.caaClient.download(imageURL: url)
        await self.diskCache.save(data: data, key: cacheKey)
        return data
    }
}

// MARK: - FetchThumbnailCache

/// Disk cache for fetched cover art thumbnails.
///
/// Stored in `<AppSupport>/Bocan/CoverArtCache/Fetch/` — separate from the
/// main cover art cache so it can be evicted independently.
private actor FetchThumbnailCache {
    private let cacheDir: URL

    init() {
        self.cacheDir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Bocan/CoverArtCache/Fetch", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.cacheDir, withIntermediateDirectories: true)
    }

    func load(key: String) -> Data? {
        let url = self.cacheDir.appendingPathComponent(key.sha256Hex + ".bin")
        return try? Data(contentsOf: url)
    }

    func save(data: Data, key: String) {
        let url = self.cacheDir.appendingPathComponent(key.sha256Hex + ".bin")
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - String sha256 helper

import CryptoKit

private extension String {
    var sha256Hex: String {
        let hash = SHA256.hash(data: Data(self.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
