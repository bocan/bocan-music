import Foundation
import Observability
import Persistence

/// The single public facade for all podcast data operations.
///
/// Owns subscribe/refresh/unsubscribe, playback-state read/write, and observation
/// streams. The App layer wires the UI data-source and `PodcastEpisodeResolving` seams.
///
/// **Design invariant**: refresh never writes to `podcast_episode_state`. State rows
/// are written exclusively by the playback bridge (`saveProgress`, `markPlayed`,
/// `markUnplayed`). The headline test in `PodcastServiceTests` guards this.
public actor PodcastService {
    let podcastRepo: PodcastRepository
    let episodeRepo: EpisodeRepository
    let stateRepo: EpisodeStateRepository
    private let transcriptRepo: TranscriptRepository
    let chaptersRepo: ChaptersRepository
    let fetcher: FeedFetcher
    private let transcriptFetcher: TranscriptFetcher
    let chaptersFetcher: ChaptersFetcher
    let parser: FeedParser
    let artwork: PodcastArtworkCache
    private let downloadStore: DownloadStore
    private let search: PodcastSearchService?
    let now: @Sendable () -> Date
    let log: AppLogger

    /// In-actor cache mapping normalized feed URL string -> podcast row id.
    /// Prevents a DB hit on every ~5-second position write.
    private var idCache: [String: Int64] = [:]

    /// Invoked after any successful refresh that discovered new episodes, with the
    /// podcast id and the new episode GUIDs. The App layer hangs auto-download off
    /// this so every refresh path (manual, `refreshAllStale`, the background
    /// scheduler) feeds the same policy. `nil` until the App wires it.
    var onRefreshNewEpisodes: (@Sendable (Int64, [String]) async -> Void)?

    /// Cached transcripts are deleted 30 days after their episode is played.
    private static let transcriptRetentionSeconds: TimeInterval = 30 * 24 * 60 * 60

    // Public initialiser that `App` calls with these labels in this order:
    // `artwork` has no default and stays among the collaborators it belongs to.
    // swiftlint:disable function_default_parameter_at_end
    /// Creates the service over its repositories. `search` is optional and
    /// `nil` by default. `transcriptHTTP` is the network seam of the
    /// transcript fetcher the service builds; `now` is the clock used for
    /// timestamps, injectable for tests.
    public init(
        podcastRepo: PodcastRepository,
        episodeRepo: EpisodeRepository,
        stateRepo: EpisodeStateRepository,
        transcriptRepo: TranscriptRepository,
        chaptersRepo: ChaptersRepository,
        fetcher: FeedFetcher = FeedFetcher(),
        parser: FeedParser = FeedParser(),
        artwork: PodcastArtworkCache,
        downloadStore: DownloadStore = DownloadStore(),
        search: PodcastSearchService? = nil,
        transcriptHTTP: any HTTPClient = URLSession.shared,
        chaptersFetcher: ChaptersFetcher = ChaptersFetcher(),
        now: @escaping @Sendable () -> Date = { Date() },
        log: AppLogger = .make(.podcasts)
    ) {
        self.podcastRepo = podcastRepo
        self.episodeRepo = episodeRepo
        self.stateRepo = stateRepo
        self.transcriptRepo = transcriptRepo
        self.chaptersRepo = chaptersRepo
        self.fetcher = fetcher
        self.transcriptFetcher = TranscriptFetcher(repo: transcriptRepo, http: transcriptHTTP, now: now)
        self.chaptersFetcher = chaptersFetcher
        self.parser = parser
        self.artwork = artwork
        self.downloadStore = downloadStore
        self.search = search
        self.now = now
        self.log = log
    }

    // swiftlint:enable function_default_parameter_at_end

    /// Registers the post-refresh new-episodes observer (see `onRefreshNewEpisodes`).
    /// Wired once by the App layer at launch.
    public func setNewEpisodesObserver(_ observer: @escaping @Sendable (Int64, [String]) async -> Void) {
        self.onRefreshNewEpisodes = observer
    }

    // MARK: - Subscriptions

    /// Fetches, parses, and persists a podcast and its current episodes.
    ///
    /// Idempotent on feed URL (upsert). Re-subscribing an already-subscribed feed
    /// refreshes its content and keeps all user-owned fields intact. Returns the
    /// podcast row id. Artwork caching is fire-and-forget (detached task).
    /// `subscribe(feedURL:indexHints:)` for callers that hold only the
    /// directory identifiers (the UI seam), not a full search result (#409).
    @discardableResult
    public func subscribe(feedURL: URL, podcastIndexID: Int?, itunesCollectionID: Int?) async throws -> Int64 {
        guard podcastIndexID != nil || itunesCollectionID != nil else {
            return try await self.subscribe(feedURL: feedURL)
        }
        let hints = PodcastSearchResult(
            canonicalFeedKey: feedURL.absoluteString,
            feedURL: feedURL,
            title: "",
            podcastIndexID: podcastIndexID,
            itunesCollectionID: itunesCollectionID
        )
        return try await self.subscribe(feedURL: feedURL, indexHints: hints)
    }

    /// Fetches and parses the feed, upserts the show and its episodes, and
    /// returns the podcast row id. The stored address is the one that
    /// answered the request, not a redirect target. `indexHints` supplies the
    /// directory identifiers for the new row. Throws
    /// `PodcastsError.invalidFeedURL` for a URL that cannot be normalised, and
    /// passes on fetch and parse errors.
    public func subscribe(feedURL: URL, indexHints: PodcastSearchResult? = nil) async throws -> Int64 {
        guard let given = FeedURL.normalizedStorageURL(feedURL) else {
            throw PodcastsError.invalidFeedURL(feedURL.absoluteString)
        }

        self.log.debug("podcast.subscribe.start", ["url": given.absoluteString])

        let fetchResult = try await fetcher.fetch(given, etag: nil, lastModified: nil)
        guard let data = fetchResult.data else {
            throw PodcastsError.network(underlying: URLError(.badServerResponse))
        }

        // Store the address that answered: the https twin when it served the
        // feed, the given http address when only that works (a feed on the
        // local network, #487). Not the redirect target: that is a move, and
        // would change the show's identity.
        let stored = FeedURL.normalizedStorageURL(fetchResult.requestedURL) ?? given
        try await self.adoptStoredScheme(stored)

        let parsed = try parser.parse(data, sourceURL: stored)

        let podcast = parsed.toPodcast(
            feedURL: stored,
            now: self.now(),
            hints: indexHints,
            etag: fetchResult.etag,
            lastModified: fetchResult.lastModified
        )

        let podcastID = try await podcastRepo.upsertByFeedURL(podcast)
        self.idCache[stored.absoluteString] = podcastID

        let episodes = parsed.episodes.map { $0.toEpisode(podcastID: podcastID, now: self.now()) }
        try await self.episodeRepo.upsertAll(episodes)

        // Apply any retention limit preserved from a prior subscription (no-op on a fresh subscribe).
        do {
            let retention = try await self.podcastRepo.fetch(id: podcastID).retentionLimit
            await self.applyRetention(podcastID: podcastID, keepNewest: retention)
        } catch {
            // The row was just upserted above, so a failure here is a real
            // database fault. Retention then goes unapplied and the show
            // quietly keeps every episode it ever had (#495).
            self.log.warning("podcast.retentionRead.failed", [
                "id": podcastID,
                "error": String(reflecting: error),
            ])
            await self.applyRetention(podcastID: podcastID, keepNewest: nil)
        }

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

    // MARK: - Episode artwork (#410)

    /// Caches the episode's own `itunes:image` (when the feed supplied one)
    /// and records the local path on the row. Returns the cached path, the
    /// already-cached path when the file still exists, or nil when the
    /// episode has no art of its own (callers fall back to the show's).
    @discardableResult
    public func cacheEpisodeArtworkIfNeeded(podcastID: Int64, guid: String) async -> String? {
        do {
            guard let episode = try await episodeRepo.fetchByGUID(podcastID: podcastID, guid: guid) else {
                return nil
            }
            return await self.cacheEpisodeArtworkIfNeeded(episode: episode, podcastID: podcastID)
        } catch {
            // The episode falls back to the show's artwork, which looks exactly
            // like a feed that supplied no episode art of its own (#495).
            self.log.warning("podcast.episodeArt.lookupFailed", [
                "id": podcastID,
                "guid": guid,
                "error": String(reflecting: error),
            ])
            return nil
        }
    }

    private func cacheEpisodeArtworkIfNeeded(episode: PodcastEpisode, podcastID: Int64) async -> String? {
        if let path = episode.artworkPath, FileManager.default.fileExists(atPath: path) {
            return path
        }
        guard let episodeID = episode.id, let urlString = episode.artworkURL, let url = URL(string: urlString) else {
            return nil
        }
        return await self.artwork.cacheEpisodeArt(episodeID: episodeID, podcastID: podcastID, url: url, repo: self.episodeRepo)
    }

    func kickEpisodeArtwork(episode: PodcastEpisode, podcastID: Int64) {
        guard episode.artworkURL != nil else { return }
        if let path = episode.artworkPath, FileManager.default.fileExists(atPath: path) {
            return
        }
        Task.detached(priority: .background) { [self] in
            await self.cacheEpisodeArtworkIfNeeded(episode: episode, podcastID: podcastID)
        }
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

    /// Sets the per-show playback-speed override (nil = use the app default).
    public func setPlaybackSpeed(_ speed: Double?, podcastID: Int64) async throws {
        try await self.podcastRepo.setPlaybackSpeed(speed, id: podcastID)
    }

    /// Sets the per-show episode-sort override ("newest" | "oldest" | nil = derive).
    public func setEpisodeSort(_ sort: String?, podcastID: Int64) async throws {
        try await self.podcastRepo.setEpisodeSort(sort, id: podcastID)
    }

    /// Sets the per-show retention limit (keep newest N; nil = keep all).
    public func setRetentionLimit(_ limit: Int?, podcastID: Int64) async throws {
        try await self.podcastRepo.setRetentionLimit(limit, id: podcastID)
    }

    // MARK: - Reads

    /// Every subscribed show, ordered by title.
    public func subscribedPodcasts() async throws -> [Podcast] {
        try await self.podcastRepo.fetchAllSubscribed()
    }

    /// The show's episodes, newest first, each joined with its play state
    /// (`state` is `nil` for an episode never played).
    public func episodes(podcastID: Int64) async throws -> [EpisodeListItem] {
        try await self.episodeRepo.fetchListItems(podcastID: podcastID)
    }

    /// Episode list in the requested sort order (per-show setting resolution lives in the UI).
    public func episodes(podcastID: Int64, order: EpisodeSortOrder) async throws -> [EpisodeListItem] {
        try await self.episodeRepo.fetchListItems(podcastID: podcastID, order: order)
    }

    /// Live list of subscribed shows, ordered by title. Emits at once and
    /// again after every change to the `podcasts` table.
    public func observeSubscribed() async -> AsyncThrowingStream<[Podcast], Error> {
        await self.podcastRepo.observeSubscribed()
    }

    /// Live episode list for the show, newest first. Emits at once and again
    /// when the show's episodes or their play state change.
    public func observeEpisodes(podcastID: Int64) async -> AsyncThrowingStream<[EpisodeListItem], Error> {
        await self.episodeRepo.observeListItems(podcastID: podcastID)
    }

    /// Live episode list in the requested sort order.
    public func observeEpisodes(
        podcastID: Int64,
        order: EpisodeSortOrder
    ) async -> AsyncThrowingStream<[EpisodeListItem], Error> {
        await self.episodeRepo.observeListItems(podcastID: podcastID, order: order)
    }

    /// Total episode counts keyed by podcast ID. A show with no episode rows
    /// is absent.
    public func episodeCounts() async throws -> [Int64: Int] {
        try await self.episodeRepo.fetchAllPodcastCounts()
    }

    /// Unread counts keyed by podcast ID (no state row or not yet played).
    /// Shows with zero unread are absent.
    public func unplayedCounts() async throws -> [Int64: Int] {
        try await self.stateRepo.unplayedCounts()
    }

    /// Live stream of unread counts; re-emits after any play-state write.
    public func observeUnplayedCounts() async -> AsyncThrowingStream<[Int64: Int], Error> {
        await self.stateRepo.observeUnplayedCounts()
    }

    /// In-progress episodes across all subscribed shows, newest first (ADR-054).
    public func continueListening() async throws -> [ContinueListeningItem] {
        try await self.stateRepo.continueListening()
    }

    /// Live Continue Listening rail; re-emits on any state/content/show change.
    public func observeContinueListening() async -> AsyncThrowingStream<[ContinueListeningItem], Error> {
        await self.stateRepo.observeContinueListening()
    }

    // MARK: - Transcripts

    /// Returns the cached transcript if present, else fetches it from the episode's
    /// `transcript_url`, stores it, and returns it. Throws `PodcastsError.notFound`
    /// when the episode has no transcript URL, or a network error on fetch.
    public func transcript(podcastID: Int64, guid: String) async throws -> PodcastTranscript {
        if let cached = try await transcriptRepo.fetch(podcastID: podcastID, guid: guid) {
            return cached
        }
        guard let episode = try await episodeRepo.fetchByGUID(podcastID: podcastID, guid: guid),
              let urlString = episode.transcriptURL,
              let url = URL(string: urlString) else {
            let feedURL = await (try? self.podcastRepo.fetch(id: podcastID)).flatMap { URL(string: $0.feedURL) }
            throw PodcastsError.notFound(
                feedURL: feedURL ?? URL(fileURLWithPath: "/podcast/\(podcastID)/\(guid)")
            )
        }
        return try await self.transcriptFetcher.fetchAndStore(
            podcastID: podcastID, guid: guid, transcriptURL: url, language: nil
        )
    }

    /// Deletes cached transcripts whose episode has been played for more than 30
    /// days. Best-effort: logs and continues on failure. Called by the scheduler at
    /// launch and after each refresh fan-out (the clock is also started by sub-phase
    /// f's "Mark all as played", which stamps `completed_at` on every episode).
    public func sweepTranscripts() async {
        let cutoff = self.now().timeIntervalSince1970 - Self.transcriptRetentionSeconds
        do {
            let deleted = try await self.transcriptRepo.deletePlayedOlderThan(cutoff: cutoff)
            if deleted > 0 {
                self.log.debug("transcript.sweep", ["deleted": deleted])
            }
        } catch {
            self.log.warning("transcript.sweep.failed", ["error": String(reflecting: error)])
        }
    }

    // MARK: - Private

    /// Resolves a feed URL to a `podcast_id`, using the in-actor cache.
    ///
    /// The cache is populated on subscribe and invalidated on unsubscribe.
    /// Called on every ~5-second position write so the cache hit rate matters.
    func resolveID(feedURL: URL) async throws -> Int64 {
        guard let stored = FeedURL.normalizedStorageURL(feedURL) else {
            throw PodcastsError.invalidFeedURL(feedURL.absoluteString)
        }
        let key = stored.absoluteString
        if let cached = idCache[key] {
            return cached
        }
        // Either scheme: a queue persisted before a subscription's stored
        // scheme was adopted (#487) still carries the old address.
        guard let podcast = try await podcastRepo.fetchByFeedURLIgnoringScheme(key) else {
            throw PodcastsError.notFound(feedURL: feedURL)
        }
        let id = podcast.id ?? 0
        self.idCache[key] = id
        return id
    }

    /// Moves a subscription stored under the other scheme of `stored` onto
    /// `stored`, so the subscribe upsert updates that row (its episodes,
    /// positions and settings stay) instead of adding a second subscription.
    /// This is how a show stored as https before #487, whose server only
    /// answers over http on the local network, is repaired by re-adding it.
    /// Only ever moves to an address whose request just succeeded; App
    /// Transport Security admits plain http only for local hosts.
    private func adoptStoredScheme(_ stored: URL) async throws {
        let key = stored.absoluteString
        guard let existing = try await self.podcastRepo.fetchByFeedURLIgnoringScheme(key),
              existing.feedURL != key else { return }
        var moved = existing
        moved.feedURL = key
        try await self.podcastRepo.update(moved)
        self.idCache[existing.feedURL] = nil
        self.log.info("podcast.subscribe.schemeAdopted", [
            "id": existing.id ?? 0,
            "from": existing.feedURL,
            "to": key,
        ])
    }
}

// MARK: - RefreshOutcome

/// Summary of a single feed refresh operation.
public struct RefreshOutcome: Sendable {
    public var notModified: Bool
    public var newEpisodeCount: Int
    public var totalEpisodeCount: Int
    /// Guids of episodes that did not exist before this refresh. Drives
    /// auto-download (ADR-043); unordered, the caller orders by publish date.
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
