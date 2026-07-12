import CryptoKit
import Foundation
import Observability
import Persistence

/// Downloads and caches podcast cover art to the local filesystem.
///
/// Cache root: `~/Library/Application Support/io.cloudcauldron.bocan/Podcasts/Artwork/<podcastID>/`.
/// Application Support is used (not Caches) so macOS never purges artwork while
/// the user has active subscriptions. File names are a truncated SHA-256 hex of
/// the remote URL so the same URL always maps to the same local path (stable
/// across app launches). Caching is best-effort: failures are logged and return
/// `nil` so the UI falls back to a gradient placeholder.
///
/// A size cap (default 15 MB) and a 10 s timeout defend against hostile image URLs. The
/// existing `Artwork(artPath:)` loader in the UI module renders the cached file
/// directly with no additional work here.
public actor PodcastArtworkCache {
    private let http: any HTTPClient
    private let root: URL
    private let maxBytes: Int
    private let log = AppLogger.make(.podcasts)

    private static let timeoutSeconds: TimeInterval = 10

    /// Cover art is commonly 3000x3000 (Apple's spec ceiling), which as a PNG can run
    /// past 5 MB, so the cap is generous; it still bounds a hostile or runaway URL.
    public static let defaultMaxBytes = 15 * 1024 * 1024

    public init(http: any HTTPClient = URLSession.shared, root: URL? = nil, maxBytes: Int = defaultMaxBytes) {
        self.http = http
        self.root = root ?? Self.defaultRoot
        self.maxBytes = maxBytes
    }

    private static let defaultRoot: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("io.cloudcauldron.bocan", isDirectory: true)
            .appendingPathComponent("Podcasts", isDirectory: true)
            .appendingPathComponent("Artwork", isDirectory: true)
    }()

    // MARK: - Public API

    /// Downloads `url` (if not already cached) to a local file under the cache
    /// root and writes its path plus its SHA-256 into the podcast row via
    /// `repo`. The hash is what Phone Sync advertises in the manifest and
    /// resolves in `GET /v1/artwork/{hash}` (phase 22-10). Best-effort; logs
    /// and returns `nil` on failure.
    @discardableResult
    public func cachePodcastArt(
        podcastID: Int64,
        url: URL?,
        repo: PodcastRepository
    ) async -> String? {
        guard let url else { return nil }
        let localURL = localPath(for: url, podcastID: podcastID)
        let localPath = localURL.path

        if FileManager.default.fileExists(atPath: localPath) {
            await self.ensureStoredArt(podcastID: podcastID, fileURL: localURL, repo: repo)
            return localPath
        }

        guard let data = await download(url: url) else { return nil }

        do {
            try FileManager.default.createDirectory(
                at: localURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: localURL)
        } catch {
            self.log.warning(
                "artwork.write.failed",
                ["podcastID": podcastID, "error": String(reflecting: error)]
            )
            return nil
        }

        await self.storeArt(podcastID: podcastID, path: localPath, hash: Self.sha256Hex(of: data), repo: repo)
        self.log.debug("artwork.cached", ["podcastID": podcastID, "path": localPath])
        return localPath
    }

    /// One-shot backfill for shows cached before the `artwork_hash` column
    /// existed (M033): hashes any subscribed show whose cached artwork file is
    /// on disk but whose row carries no hash, so existing libraries advertise
    /// art on the next sync without re-fetching feeds. A missing file is
    /// skipped (the manifest advertises `nil` for it).
    public func backfillArtworkHashes(repo: PodcastRepository) async {
        let shows: [Podcast]
        do {
            shows = try await repo.fetchAllSubscribed()
        } catch {
            self.log.warning("artwork.backfill.fetchFailed", ["error": String(reflecting: error)])
            return
        }
        var hashed = 0
        for show in shows {
            if Task.isCancelled { return }
            guard let id = show.id, show.artworkHash == nil, let path = show.artworkPath,
                  FileManager.default.fileExists(atPath: path),
                  let hash = self.sha256Hex(ofFileAt: URL(fileURLWithPath: path)) else { continue }
            await self.storeArt(podcastID: id, path: path, hash: hash, repo: repo)
            hashed += 1
        }
        if hashed > 0 {
            self.log.info("artwork.backfill.end", ["hashed": hashed])
        }
    }

    /// Downloads episode-level artwork (when present) and writes its path into
    /// the episode row via `repo`. Best-effort.
    @discardableResult
    public func cacheEpisodeArt(
        episodeID: Int64,
        podcastID: Int64,
        url: URL?,
        repo: EpisodeRepository
    ) async -> String? {
        guard let url else { return nil }
        let localURL = localPath(for: url, podcastID: podcastID)
        let localPath = localURL.path

        if FileManager.default.fileExists(atPath: localPath) {
            await self.updateEpisodePath(episodeID: episodeID, path: localPath, repo: repo)
            return localPath
        }

        guard let data = await download(url: url) else { return nil }

        do {
            try FileManager.default.createDirectory(
                at: localURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: localURL)
        } catch {
            self.log.warning(
                "artwork.episode.write.failed",
                ["episodeID": episodeID, "error": String(reflecting: error)]
            )
            return nil
        }

        await self.updateEpisodePath(episodeID: episodeID, path: localPath, repo: repo)
        self.log.debug("artwork.episode.cached", ["episodeID": episodeID, "path": localPath])
        return localPath
    }

    /// Removes the show's entire artwork directory. Called on unsubscribe.
    public func evict(podcastID: Int64) async {
        let dir = self.root.appendingPathComponent("\(podcastID)", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        do {
            try FileManager.default.removeItem(at: dir)
            self.log.debug("artwork.evicted", ["podcastID": podcastID])
        } catch {
            self.log.warning(
                "artwork.evict.failed",
                ["podcastID": podcastID, "error": String(reflecting: error)]
            )
        }
    }

    // MARK: - Private helpers

    private func localPath(for url: URL, podcastID: Int64) -> URL {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = String(hash.map { String(format: "%02x", $0) }.joined().prefix(16))
        let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
        let filename = "\(hex).\(ext)"
        return self.root
            .appendingPathComponent("\(podcastID)", isDirectory: true)
            .appendingPathComponent(filename)
    }

    private func download(url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: Self.timeoutSeconds)
        request.setValue(UserAgent.string, forHTTPHeaderField: "User-Agent")
        self.log.debug("artwork.download.start", ["url": url.absoluteString])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await self.http.data(for: request)
        } catch {
            self.log.warning(
                "artwork.download.networkFailed",
                ["url": url.absoluteString, "error": String(reflecting: error)]
            )
            return nil
        }

        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            self.log.warning(
                "artwork.download.httpError",
                ["url": url.absoluteString, "status": http.statusCode]
            )
            return nil
        }

        if data.count > self.maxBytes {
            self.log.warning(
                "artwork.download.tooLarge",
                ["url": url.absoluteString, "bytes": data.count]
            )
            return nil
        }

        self.log.debug("artwork.download.end", ["url": url.absoluteString, "bytes": data.count])
        return data
    }

    /// Stores path + hash for an already-cached file, unless the row is
    /// current. Refresh reaches this on every cycle through the exists
    /// short-circuit, so an unchanged row costs one fetch and no hash, no
    /// write (a needless write would also bump the Phone Sync generation).
    private func ensureStoredArt(podcastID: Int64, fileURL: URL, repo: PodcastRepository) async {
        let path = fileURL.path
        do {
            let podcast = try await repo.fetch(id: podcastID)
            if podcast.artworkPath == path, podcast.artworkHash != nil { return }
        } catch {
            self.log.warning(
                "artwork.fetchRow.failed",
                ["podcastID": podcastID, "error": String(reflecting: error)]
            )
            return
        }
        await self.storeArt(podcastID: podcastID, path: path, hash: self.sha256Hex(ofFileAt: fileURL), repo: repo)
    }

    private func storeArt(podcastID: Int64, path: String, hash: String?, repo: PodcastRepository) async {
        do {
            try await repo.setArtwork(id: podcastID, path: path, hash: hash)
        } catch {
            self.log.warning(
                "artwork.updatePodcastArt.failed",
                ["podcastID": podcastID, "error": String(reflecting: error)]
            )
        }
    }

    private static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The file's SHA-256, or `nil` (logged) when it cannot be read. Art is
    /// capped at `maxBytes`, so a whole-file read is fine here.
    private func sha256Hex(ofFileAt url: URL) -> String? {
        do {
            return try Self.sha256Hex(of: Data(contentsOf: url))
        } catch {
            self.log.warning(
                "artwork.hash.readFailed",
                ["path": url.path, "error": String(reflecting: error)]
            )
            return nil
        }
    }

    private func updateEpisodePath(
        episodeID: Int64,
        path: String,
        repo: EpisodeRepository
    ) async {
        do {
            var episode = try await repo.fetch(id: episodeID)
            episode.artworkPath = path
            // Use upsert which updates artwork_path via ON CONFLICT DO UPDATE.
            _ = try await repo.upsert(episode)
        } catch {
            self.log.warning(
                "artwork.updateEpisodePath.failed",
                ["episodeID": episodeID, "error": String(reflecting: error)]
            )
        }
    }
}
