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
/// A 5 MB cap and a 10 s timeout defend against hostile image URLs. The
/// existing `Artwork(artPath:)` loader in the UI module renders the cached file
/// directly with no additional work here.
public actor PodcastArtworkCache {
    private let http: any HTTPClient
    private let root: URL
    private let log = AppLogger.make(.podcasts)

    private static let maxBytes = 5 * 1024 * 1024
    private static let timeoutSeconds: TimeInterval = 10

    public init(http: any HTTPClient = URLSession.shared, root: URL? = nil) {
        self.http = http
        self.root = root ?? Self.defaultRoot
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
    /// root and writes its path into `podcasts.artwork_path` via `repo`.
    /// Best-effort; logs and returns `nil` on failure.
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
            await self.updatePodcastPath(podcastID: podcastID, path: localPath, repo: repo)
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

        await self.updatePodcastPath(podcastID: podcastID, path: localPath, repo: repo)
        self.log.debug("artwork.cached", ["podcastID": podcastID, "path": localPath])
        return localPath
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
        request.setValue("Bocan Podcast-Reader", forHTTPHeaderField: "User-Agent")
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

        if data.count > Self.maxBytes {
            self.log.warning(
                "artwork.download.tooLarge",
                ["url": url.absoluteString, "bytes": data.count]
            )
            return nil
        }

        self.log.debug("artwork.download.end", ["url": url.absoluteString, "bytes": data.count])
        return data
    }

    private func updatePodcastPath(
        podcastID: Int64,
        path: String,
        repo: PodcastRepository
    ) async {
        do {
            var podcast = try await repo.fetch(id: podcastID)
            podcast.artworkPath = path
            try await repo.update(podcast)
        } catch {
            self.log.warning(
                "artwork.updatePodcastPath.failed",
                ["podcastID": podcastID, "error": String(reflecting: error)]
            )
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
