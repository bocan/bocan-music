import Foundation
import Observability
import Persistence

/// The single public facade for all podcast data operations.
///
/// Owns subscribe/refresh/unsubscribe, playback-state read/write, and observation
/// streams. The App layer wires the UI data-source seam (phase 21-7) and the
/// `PodcastEpisodeResolving` seam (phase 21-5) by forwarding directly to these methods.
///
/// **Design invariant**: refresh never writes to `podcast_episode_state`. State rows
/// are written exclusively by the playback bridge (`saveProgress`, `markPlayed`,
/// `markUnplayed`). The headline test in `PodcastServiceTests` guards this.
///
/// **Unsubscribe** performs a hard delete (MVP). State cascades away on deletion.
/// A future soft-delete can be added by setting `subscribed = false` instead;
/// call out the trade-off in the UI: "Unsubscribe removes playback history for
/// this show."
public actor PodcastService {
    private let podcastRepo: PodcastRepository
    private let episodeRepo: EpisodeRepository
    private let stateRepo: EpisodeStateRepository
    private let fetcher: FeedFetcher
    private let parser: FeedParser
    private let artwork: PodcastArtworkCache
    private let downloadStore: DownloadStore
    private let search: PodcastSearchService?
    private let now: @Sendable () -> Date
    private let log: AppLogger

    /// In-actor cache mapping normalized feed URL string -> podcast row id.
    /// Prevents a DB hit on every ~5-second position write.
    private var idCache: [String: Int64] = [:]

    public init(
        podcastRepo: PodcastRepository,
        episodeRepo: EpisodeRepository,
        stateRepo: EpisodeStateRepository,
        fetcher: FeedFetcher = FeedFetcher(),
        parser: FeedParser = FeedParser(),
        artwork: PodcastArtworkCache,
        downloadStore: DownloadStore = DownloadStore(),
        search: PodcastSearchService? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        log: AppLogger = .make(.podcasts)
    ) {
        self.podcastRepo = podcastRepo
        self.episodeRepo = episodeRepo
        self.stateRepo = stateRepo
        self.fetcher = fetcher
        self.parser = parser
        self.artwork = artwork
        self.downloadStore = downloadStore
        self.search = search
        self.now = now
        self.log = log
    }

    // MARK: - Subscriptions

    /// Fetches, parses, and persists a podcast and its current episodes.
    ///
    /// Idempotent on feed URL (upsert). Re-subscribing an already-subscribed feed
    /// refreshes its content and keeps all user-owned fields intact. Returns the
    /// podcast row id. Artwork caching is fire-and-forget (detached task).
    @discardableResult
    public func subscribe(feedURL: URL, indexHints: PodcastSearchResult? = nil) async throws -> Int64 {
        guard let stored = FeedURL.normalizedStorageURL(feedURL) else {
            throw PodcastsError.invalidFeedURL(feedURL.absoluteString)
        }

        self.log.debug("podcast.subscribe.start", ["url": stored.absoluteString])

        let fetchResult = try await fetcher.fetch(stored, etag: nil, lastModified: nil)
        guard let data = fetchResult.data else {
            throw PodcastsError.network(underlying: URLError(.badServerResponse))
        }

        let parsed = try parser.parse(data, sourceURL: stored)

        let podcast = parsed.toPodcast(
            feedURL: stored,
            hints: indexHints,
            etag: fetchResult.etag,
            lastModified: fetchResult.lastModified,
            now: self.now()
        )

        let podcastID = try await podcastRepo.upsertByFeedURL(podcast)
        self.idCache[stored.absoluteString] = podcastID

        let episodes = parsed.episodes.map { $0.toEpisode(podcastID: podcastID, now: self.now()) }
        try await self.episodeRepo.upsertAll(episodes)

        // Fire artwork download as a non-blocking detached task; subscribe returns immediately.
        let art = self.artwork
        let artURL = parsed.artworkURL
        let repo = self.podcastRepo
        Task.detached(priority: .background) { [art, repo] in
            await art.cachePodcastArt(podcastID: podcastID, url: artURL, repo: repo)
        }

        self.log.debug(
            "podcast.subscribe.end",
            ["id": podcastID, "title": parsed.title, "episodes": episodes.count]
        )
        return podcastID
    }

    /// Removes a podcast and all its episodes and state (hard delete / cascade).
    /// Evicts cached artwork. Invalidates the id cache entry.
    public func unsubscribe(podcastID: Int64) async throws {
        let podcast = try await podcastRepo.fetch(id: podcastID)
        try await self.podcastRepo.delete(id: podcastID)
        self.idCache.removeValue(forKey: podcast.feedURL)
        // Evict artwork (fast filesystem op; awaited so callers see clean state).
        await self.artwork.evict(podcastID: podcastID)
        // Delete every downloaded episode for the show (state cascades via the DB).
        self.downloadStore.deletePodcast(podcastID: podcastID)
        self.log.info("podcast.unsubscribe", ["id": podcastID, "title": podcast.title])
    }

    /// Toggles auto-download for a podcast.
    public func setAutoDownload(_ on: Bool, podcastID: Int64) async throws {
        var podcast = try await podcastRepo.fetch(id: podcastID)
        podcast.autoDownload = on
        try await self.podcastRepo.update(podcast)
    }

    /// Persists a user-defined sort order by writing `sort_index = position`.
    public func reorder(podcastIDs: [Int64]) async throws {
        for (index, id) in podcastIDs.enumerated() {
            try await self.podcastRepo.setSortIndex(id: id, sortIndex: index)
        }
    }

    // MARK: - Refresh

    /// Conditional GET; on 304 just stamps `last_refreshed_at`; on 200 upserts
    /// episodes (content only) and caches any new artwork.
    ///
    /// **Never** writes to `podcast_episode_state`.
    ///
    /// - Returns: `RefreshOutcome` describing what changed.
    /// - Throws: Network / parse errors. Callers (e.g. a refresh button) can
    ///   surface these as a toast; `refreshAllStale` catches per-feed.
    @discardableResult
    public func refresh(podcastID: Int64) async throws -> RefreshOutcome {
        let podcast = try await podcastRepo.fetch(id: podcastID)
        guard let feedURL = URL(string: podcast.feedURL) else {
            throw PodcastsError.invalidFeedURL(podcast.feedURL)
        }

        self.log.debug("podcast.refresh.start", ["id": podcastID, "url": podcast.feedURL])

        let fetchResult: FeedFetchResult
        do {
            fetchResult = try await self.fetcher.fetch(
                feedURL,
                etag: podcast.httpETag,
                lastModified: podcast.httpLastModified
            )
        } catch {
            // Stamp the error for display but rethrow so the caller can react.
            var failed = podcast
            failed.lastRefreshedAt = self.now().timeIntervalSince1970
            failed.lastRefreshError = error.localizedDescription
            do {
                try await self.podcastRepo.update(failed)
            } catch {
                self.log.warning(
                    "podcast.refresh.stampFailed",
                    ["id": podcastID, "error": String(reflecting: error)]
                )
            }
            self.log.warning("podcast.refresh.fetchFailed", ["id": podcastID, "error": String(reflecting: error)])
            throw error
        }

        // 304 Not Modified: just stamp the timestamp and clear any previous error.
        if fetchResult.notModified {
            var stamped = podcast
            stamped.lastRefreshedAt = self.now().timeIntervalSince1970
            stamped.lastRefreshError = nil
            try await self.podcastRepo.update(stamped)
            self.log.debug("podcast.refresh.notModified", ["id": podcastID])
            return RefreshOutcome(notModified: true, newEpisodeCount: 0, totalEpisodeCount: 0)
        }

        guard let data = fetchResult.data else {
            throw PodcastsError.network(underlying: URLError(.badServerResponse))
        }

        let parsed = try parser.parse(data, sourceURL: feedURL)

        // Count existing GUIDs to determine how many episodes are new.
        let existingEpisodes = try await episodeRepo.fetchForPodcast(podcastID: podcastID)
        let existingGUIDs = Set(existingEpisodes.map(\.guid))
        let newGUIDs = Set(parsed.episodes.map(\.guid)).subtracting(existingGUIDs)

        // Upsert channel (preserves user-owned fields via upsertByFeedURL).
        var updatedPodcast = parsed.toPodcast(
            feedURL: feedURL,
            etag: fetchResult.etag,
            lastModified: fetchResult.lastModified,
            now: self.now()
        )
        updatedPodcast.lastRefreshError = nil
        try await self.podcastRepo.upsertByFeedURL(updatedPodcast)

        // Upsert episodes -- content only. State rows are NEVER touched here.
        let episodes = parsed.episodes.map { $0.toEpisode(podcastID: podcastID, now: self.now()) }
        try await self.episodeRepo.upsertAll(episodes)

        // Cache artwork if the URL changed.
        if podcast.artworkURL != parsed.artworkURL?.absoluteString {
            let art = self.artwork
            let artURL = parsed.artworkURL
            let repo = self.podcastRepo
            Task.detached(priority: .background) { [art, repo] in
                await art.cachePodcastArt(podcastID: podcastID, url: artURL, repo: repo)
            }
        }

        self.log.debug(
            "podcast.refresh.end",
            ["id": podcastID, "new": newGUIDs.count, "total": episodes.count]
        )
        return RefreshOutcome(
            notModified: false,
            newEpisodeCount: newGUIDs.count,
            totalEpisodeCount: episodes.count,
            newEpisodeGUIDs: Array(newGUIDs)
        )
    }

    /// Best-effort batch refresh. Feeds that fail are logged per-feed and do not
    /// interrupt the remaining batch.
    public func refreshAllStale(olderThan: TimeInterval = 3600) async {
        let stale: [Podcast]
        do {
            stale = try await self.podcastRepo.fetchStale(
                olderThan: olderThan,
                now: self.now().timeIntervalSince1970
            )
        } catch {
            self.log.error(
                "podcast.refreshAllStale.fetchFailed",
                ["error": String(reflecting: error)]
            )
            return
        }

        self.log.debug("podcast.refreshAllStale.start", ["count": stale.count])
        for podcast in stale {
            if Task.isCancelled { return }
            guard let podcastID = podcast.id else { continue }
            do {
                _ = try await self.refresh(podcastID: podcastID)
            } catch {
                self.log.warning(
                    "podcast.refresh.perFeedFailed",
                    ["id": podcastID, "url": podcast.feedURL, "error": String(reflecting: error)]
                )
            }
        }
    }

    // MARK: - Reads

    public func subscribedPodcasts() async throws -> [Podcast] {
        try await self.podcastRepo.fetchAllSubscribed()
    }

    public func episodes(podcastID: Int64) async throws -> [EpisodeListItem] {
        try await self.episodeRepo.fetchListItems(podcastID: podcastID)
    }

    public func observeSubscribed() async -> AsyncThrowingStream<[Podcast], Error> {
        await self.podcastRepo.observeSubscribed()
    }

    public func observeEpisodes(podcastID: Int64) async -> AsyncThrowingStream<[EpisodeListItem], Error> {
        await self.episodeRepo.observeListItems(podcastID: podcastID)
    }

    // MARK: - Playback-state bridge

    /// Returns the enclosure URL for an episode (or a local file URL when downloaded).
    public func audioURL(feedURL: URL, episodeGUID: String) async throws -> URL {
        let podcastID = try await resolveID(feedURL: feedURL)
        guard let episode = try await episodeRepo.fetchByGUID(
            podcastID: podcastID,
            guid: episodeGUID
        ) else {
            throw PodcastsError.notFound(feedURL: feedURL)
        }

        // Return the downloaded file URL when available (phase 21-6 populates this).
        // State, not the file, is the source of truth for the badge, but verify the
        // file actually exists: a user may have cleared Application Support out of
        // band. If the state says downloaded but the file is gone, reset state to
        // none and stream instead.
        if let state = try await stateRepo.fetch(podcastID: podcastID, guid: episodeGUID),
           state.downloadState == .downloaded,
           let path = state.downloadPath {
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
            self.log.warning(
                "podcast.audioURL.downloadMissing",
                ["podcastID": podcastID, "guid": episodeGUID]
            )
            do {
                try await self.stateRepo.setDownloadState(
                    podcastID: podcastID, guid: episodeGUID, state: .none, path: nil, bytes: nil
                )
            } catch {
                self.log.warning(
                    "podcast.audioURL.resetFailed",
                    ["guid": episodeGUID, "error": String(reflecting: error)]
                )
            }
        }

        guard let url = URL(string: episode.audioURL) else {
            throw PodcastsError.invalidFeedURL(episode.audioURL)
        }
        return url
    }

    /// Returns the saved resume position, or 0 when unplayed or effectively complete.
    public func resumePosition(feedURL: URL, episodeGUID: String) async -> TimeInterval {
        do {
            let podcastID = try await resolveID(feedURL: feedURL)
            guard let state = try await stateRepo.fetch(podcastID: podcastID, guid: episodeGUID) else {
                return 0
            }
            if state.playState == .played { return 0 }
            if let episode = try await episodeRepo.fetchByGUID(
                podcastID: podcastID,
                guid: episodeGUID
            ),
                let duration = episode.duration,
                duration > 0,
                state.playPosition >= duration - PodcastPlayback.completionTailSeconds {
                return 0
            }
            return state.playPosition
        } catch {
            self.log.warning(
                "podcast.resumePosition.failed",
                ["error": String(reflecting: error)]
            )
            return 0
        }
    }

    /// Persists the current play position. If within `PodcastPlayback.completionTailSeconds`
    /// of the end, auto-marks the episode played. Ignores position <= 0.
    public func saveProgress(
        feedURL: URL,
        episodeGUID: String,
        position: TimeInterval,
        duration: TimeInterval
    ) async {
        guard position > 0 else { return }
        do {
            let podcastID = try await resolveID(feedURL: feedURL)
            let ts = self.now().timeIntervalSince1970
            if duration > 0, position >= duration - PodcastPlayback.completionTailSeconds {
                try await self.stateRepo.markPlayed(podcastID: podcastID, guid: episodeGUID, now: ts)
            } else {
                try await self.stateRepo.savePosition(
                    podcastID: podcastID,
                    guid: episodeGUID,
                    position: position,
                    now: ts
                )
            }
        } catch {
            self.log.warning(
                "podcast.saveProgress.failed",
                ["error": String(reflecting: error)]
            )
        }
    }

    /// Marks the episode fully played.
    public func markPlayed(feedURL: URL, episodeGUID: String) async {
        do {
            let podcastID = try await resolveID(feedURL: feedURL)
            try await stateRepo.markPlayed(
                podcastID: podcastID,
                guid: episodeGUID,
                now: self.now().timeIntervalSince1970
            )
        } catch {
            self.log.warning(
                "podcast.markPlayed.failed",
                ["error": String(reflecting: error)]
            )
        }
    }

    /// Resets the episode to unplayed with position 0.
    public func markUnplayed(feedURL: URL, episodeGUID: String) async {
        do {
            let podcastID = try await resolveID(feedURL: feedURL)
            try await stateRepo.markUnplayed(podcastID: podcastID, guid: episodeGUID)
        } catch {
            self.log.warning(
                "podcast.markUnplayed.failed",
                ["error": String(reflecting: error)]
            )
        }
    }

    /// Marks the episode fully played by podcast database ID.
    ///
    /// Used by the UI `PodcastActions` seam, which fires by `podcastID` rather
    /// than feedURL (no URL cache lookup needed here).
    public func markPlayed(podcastID: Int64, guid: String) async {
        do {
            try await self.stateRepo.markPlayed(
                podcastID: podcastID,
                guid: guid,
                now: self.now().timeIntervalSince1970
            )
        } catch {
            self.log.warning(
                "podcast.markPlayed.byID.failed",
                ["error": String(reflecting: error)]
            )
        }
    }

    /// Resets the episode to unplayed with position 0 by podcast database ID.
    ///
    /// Used by the UI `PodcastActions` seam; bypasses the feedURL cache.
    public func markUnplayed(podcastID: Int64, guid: String) async {
        do {
            try await self.stateRepo.markUnplayed(podcastID: podcastID, guid: guid)
        } catch {
            self.log.warning(
                "podcast.markUnplayed.byID.failed",
                ["error": String(reflecting: error)]
            )
        }
    }

    // MARK: - Private

    /// Resolves a feed URL to a `podcast_id`, using the in-actor cache.
    ///
    /// The cache is populated on subscribe and invalidated on unsubscribe.
    /// Called on every ~5-second position write so the cache hit rate matters.
    private func resolveID(feedURL: URL) async throws -> Int64 {
        guard let stored = FeedURL.normalizedStorageURL(feedURL) else {
            throw PodcastsError.invalidFeedURL(feedURL.absoluteString)
        }
        let key = stored.absoluteString
        if let cached = idCache[key] { return cached }
        guard let podcast = try await podcastRepo.fetchByFeedURL(key) else {
            throw PodcastsError.notFound(feedURL: feedURL)
        }
        let id = podcast.id ?? 0
        self.idCache[key] = id
        return id
    }
}

// MARK: - RefreshOutcome

/// Summary of a single feed refresh operation.
public struct RefreshOutcome: Sendable {
    public var notModified: Bool
    public var newEpisodeCount: Int
    public var totalEpisodeCount: Int
    /// Guids of episodes that did not exist before this refresh. Drives
    /// auto-download (phase 21-6); unordered, the caller orders by publish date.
    public var newEpisodeGUIDs: [String]

    public init(
        notModified: Bool,
        newEpisodeCount: Int,
        totalEpisodeCount: Int,
        newEpisodeGUIDs: [String] = []
    ) {
        self.notModified = notModified
        self.newEpisodeCount = newEpisodeCount
        self.totalEpisodeCount = totalEpisodeCount
        self.newEpisodeGUIDs = newEpisodeGUIDs
    }
}
