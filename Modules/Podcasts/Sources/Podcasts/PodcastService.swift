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
    private let podcastRepo: PodcastRepository
    private let episodeRepo: EpisodeRepository
    private let stateRepo: EpisodeStateRepository
    private let transcriptRepo: TranscriptRepository
    private let fetcher: FeedFetcher
    private let transcriptFetcher: TranscriptFetcher
    private let chaptersFetcher: ChaptersFetcher
    private let parser: FeedParser
    private let artwork: PodcastArtworkCache
    private let downloadStore: DownloadStore
    private let search: PodcastSearchService?
    private let now: @Sendable () -> Date
    private let log: AppLogger

    /// In-actor cache mapping normalized feed URL string -> podcast row id.
    /// Prevents a DB hit on every ~5-second position write.
    private var idCache: [String: Int64] = [:]

    /// Invoked after any successful refresh that discovered new episodes, with the
    /// podcast id and the new episode GUIDs. The App layer hangs auto-download off
    /// this so every refresh path (manual, `refreshAllStale`, the background
    /// scheduler) feeds the same policy. `nil` until the App wires it.
    private var onRefreshNewEpisodes: (@Sendable (Int64, [String]) async -> Void)?

    /// Cached transcripts are deleted 30 days after their episode is played.
    private static let transcriptRetentionSeconds: TimeInterval = 30 * 24 * 60 * 60

    public init(
        podcastRepo: PodcastRepository,
        episodeRepo: EpisodeRepository,
        stateRepo: EpisodeStateRepository,
        transcriptRepo: TranscriptRepository,
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
        self.fetcher = fetcher
        self.transcriptFetcher = TranscriptFetcher(http: transcriptHTTP, repo: transcriptRepo, now: now)
        self.chaptersFetcher = chaptersFetcher
        self.parser = parser
        self.artwork = artwork
        self.downloadStore = downloadStore
        self.search = search
        self.now = now
        self.log = log
    }

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

        // Apply any retention limit preserved from a prior subscription (no-op on a fresh subscribe).
        let retention = await (try? self.podcastRepo.fetch(id: podcastID))?.retentionLimit
        await self.applyRetention(podcastID: podcastID, keepNewest: retention)

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
            // Self-heal a missing cover image even when the feed is unchanged.
            self.ensureArtworkCached(
                podcastID: podcastID,
                url: podcast.artworkURL.flatMap { URL(string: $0) },
                existingPath: podcast.artworkPath,
                urlChanged: false
            )
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

        // Apply the show's retention limit after the upsert (best-effort).
        await self.applyRetention(podcastID: podcastID, keepNewest: podcast.retentionLimit)

        // Re-cache artwork when the remote URL changed or the cached file is gone.
        // `artwork_path` is preserved across refreshes (see `upsertByFeedURL`), so a
        // stable cached image needs no re-download; this also self-heals a wiped file.
        self.ensureArtworkCached(
            podcastID: podcastID,
            url: parsed.artworkURL,
            existingPath: podcast.artworkPath,
            urlChanged: podcast.artworkURL != parsed.artworkURL?.absoluteString
        )

        self.log.debug(
            "podcast.refresh.end",
            ["id": podcastID, "new": newGUIDs.count, "total": episodes.count]
        )

        // Notify the auto-download policy (if wired) about freshly discovered
        // episodes. Runs after the content upsert so the observer can read them.
        if !newGUIDs.isEmpty {
            await self.onRefreshNewEpisodes?(podcastID, Array(newGUIDs))
        }

        return RefreshOutcome(
            notModified: false,
            newEpisodeCount: newGUIDs.count,
            totalEpisodeCount: episodes.count,
            newEpisodeGUIDs: Array(newGUIDs)
        )
    }

    /// Re-downloads cover art (detached, best-effort) when the remote URL changed
    /// or the locally cached file is missing. A no-op once a stable file exists, so
    /// it is cheap to call on every refresh. `cachePodcastArt` itself short-circuits
    /// when the target file is already present.
    private func ensureArtworkCached(podcastID: Int64, url: URL?, existingPath: String?, urlChanged: Bool) {
        let fileMissing = existingPath.map { !FileManager.default.fileExists(atPath: $0) } ?? true
        guard urlChanged || fileMissing, let url else { return }
        let art = self.artwork
        let repo = self.podcastRepo
        Task.detached(priority: .background) { [art, repo] in
            await art.cachePodcastArt(podcastID: podcastID, url: url, repo: repo)
        }
    }

    /// One-shot Phone Sync backfill (phase 22-10): hashes cached show art that
    /// predates the `artwork_hash` column so existing subscriptions advertise
    /// artwork on the next sync. Call once at startup; cheap when there is
    /// nothing to do.
    public func backfillArtworkHashes() async {
        await self.artwork.backfillArtworkHashes(repo: self.podcastRepo)
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

    /// Applies a show's retention limit, best-effort: never throws so it cannot
    /// fail a subscribe/refresh. Nil limit is a no-op (keep all).
    private func applyRetention(podcastID: Int64, keepNewest: Int?) async {
        guard keepNewest != nil else { return }
        do {
            try await self.podcastRepo.pruneEpisodes(podcastID: podcastID, keepNewest: keepNewest)
        } catch {
            self.log.debug("podcast.prune.failed", ["id": podcastID, "error": String(reflecting: error)])
        }
    }

    // MARK: - Reads

    public func subscribedPodcasts() async throws -> [Podcast] {
        try await self.podcastRepo.fetchAllSubscribed()
    }

    public func episodes(podcastID: Int64) async throws -> [EpisodeListItem] {
        try await self.episodeRepo.fetchListItems(podcastID: podcastID)
    }

    /// Episode list in the requested sort order (per-show setting resolution lives in the UI).
    public func episodes(podcastID: Int64, order: EpisodeSortOrder) async throws -> [EpisodeListItem] {
        try await self.episodeRepo.fetchListItems(podcastID: podcastID, order: order)
    }

    public func observeSubscribed() async -> AsyncThrowingStream<[Podcast], Error> {
        await self.podcastRepo.observeSubscribed()
    }

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

    // MARK: - OPML import / export

    /// Imports an OPML subscription list: parse, dedupe (intra-file and against
    /// existing subscriptions via `FeedURL.canonicalKey`), then subscribe the
    /// remainder sequentially with progress.
    ///
    /// A malformed document throws up front, before any subscribe. Per-feed
    /// subscribe failures are collected into the summary and never abort the
    /// batch. A cancelled import returns the summary-so-far without throwing.
    /// `progress` is called `(completed, total)` after each subscribe attempt.
    public func importOPML(
        data: Data,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> OPMLImportSummary {
        let entries = try OPMLReader.parse(data: data)

        // Drop intra-file duplicates by canonical key (keep first).
        var seen = Set<String>()
        let unique = entries.filter { seen.insert(FeedURL.canonicalKey($0.feedURL)).inserted }

        // Partition against existing subscriptions. A cancellation here (before any
        // subscribe) returns an empty summary rather than throwing.
        let existing: [Podcast]
        do {
            existing = try await self.subscribedPodcasts()
        } catch is CancellationError {
            return OPMLImportSummary()
        }
        let existingKeys = Set(existing.compactMap { URL(string: $0.feedURL).map(FeedURL.canonicalKey) })

        var summary = OPMLImportSummary()
        var toSubscribe: [OPMLEntry] = []
        for entry in unique {
            if existingKeys.contains(FeedURL.canonicalKey(entry.feedURL)) {
                summary.alreadySubscribed.append(OPMLImportItem(
                    title: entry.title,
                    feedURL: entry.feedURL,
                    reason: "Already subscribed"
                ))
            } else {
                toSubscribe.append(entry)
            }
        }

        let total = toSubscribe.count
        var completed = 0
        for entry in toSubscribe {
            if Task.isCancelled {
                self.log.info("podcast.opml.import.cancelled", ["completed": completed, "total": total])
                return summary
            }
            do {
                _ = try await self.subscribe(feedURL: entry.feedURL)
                summary.succeeded.append(OPMLImportItem(
                    title: entry.title,
                    feedURL: entry.feedURL,
                    reason: "Subscribed"
                ))
            } catch is CancellationError {
                self.log.info("podcast.opml.import.cancelled", ["completed": completed, "total": total])
                return summary
            } catch {
                let reason = (error as? PodcastsError)?.description ?? error.localizedDescription
                summary.failed.append(OPMLImportItem(title: entry.title, feedURL: entry.feedURL, reason: reason))
            }
            completed += 1
            progress?(completed, total)
        }

        self.log.info("podcast.opml.import", [
            "succeeded": summary.succeeded.count,
            "alreadySubscribed": summary.alreadySubscribed.count,
            "failed": summary.failed.count,
        ])
        return summary
    }

    /// Serializes the current subscriptions to OPML 2.0 UTF-8 `Data`. The UI
    /// owns the save panel and the atomic `data.write(to:)`.
    public func exportOPML() async throws -> Data {
        let opml = try await OPMLWriter.write(self.subscribedPodcasts(), now: self.now())
        guard let data = opml.data(using: .utf8) else {
            throw PodcastsError.parseFailed(url: URL(fileURLWithPath: "opml-export"), reason: "UTF-8 encoding failed")
        }
        return data
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

    /// Marks the episode fully played by podcast database ID (UI seam, bypasses feedURL cache).
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

    /// Resets the episode to unplayed with position 0 by podcast database ID (UI seam).
    public func markUnplayed(podcastID: Int64, guid: String) async {
        do {
            try await self.stateRepo.markUnplayed(podcastID: podcastID, guid: guid)
        } catch {
            self.log.warning("podcast.markUnplayed.byID.failed", ["error": String(reflecting: error)])
        }
    }

    /// Marks all episodes for a podcast as played (UI seam).
    public func markAllPlayed(podcastID: Int64) async {
        do {
            try await self.stateRepo.markAllPlayed(podcastID: podcastID, now: self.now().timeIntervalSince1970)
        } catch {
            self.log.warning("podcast.markAllPlayed.failed", ["error": String(reflecting: error)])
        }
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

    // MARK: - Chapters

    /// Fetches the chapter list for an episode from its `chapters_url`. Returns
    /// `[]` when the episode has no chapters URL. The fetch may throw (network /
    /// HTTP / size); callers map a throw to "no chapters".
    public func chapters(podcastID: Int64, guid: String) async throws -> [Chapter] {
        guard let episode = try await episodeRepo.fetchByGUID(podcastID: podcastID, guid: guid),
              let urlString = episode.chaptersURL,
              let url = URL(string: urlString) else {
            return []
        }
        return try await self.chaptersFetcher.chapters(for: url)
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
