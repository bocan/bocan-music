import Foundation
import Observability
import Persistence

// MARK: - Refresh

/// Feed refresh: one show, or every stale show. Content rows only, never play state.
public extension PodcastService {
    /// Conditional GET; on 304 just stamps `last_refreshed_at`; on 200 upserts
    /// episodes (content only) and caches any new artwork.
    ///
    /// **Never** writes to `podcast_episode_state`.
    ///
    /// - Returns: `RefreshOutcome` describing what changed.
    /// - Throws: Network / parse errors. Callers (e.g. a refresh button) can
    ///   surface these as a toast; `refreshAllStale` catches per-feed.
    @discardableResult
    func refresh(podcastID: Int64) async throws -> RefreshOutcome {
        let podcast = try await podcastRepo.fetch(id: podcastID)
        guard let feedURL = URL(string: podcast.feedURL) else {
            throw PodcastsError.invalidFeedURL(podcast.feedURL)
        }

        self.log.debug("podcast.refresh.start", ["id": podcastID, "url": podcast.feedURL])

        let fetchResult = try await self.fetchForRefresh(podcast, feedURL: feedURL, podcastID: podcastID)

        // 304 Not Modified: just stamp the timestamp and clear any previous error.
        if fetchResult.notModified {
            return try await self.stampNotModified(podcast, podcastID: podcastID)
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
            now: self.now(),
            etag: fetchResult.etag,
            lastModified: fetchResult.lastModified
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

    /// One-shot Phone Sync backfill (ADR-070): hashes cached show art that
    /// predates the `artwork_hash` column so existing subscriptions advertise
    /// artwork on the next sync. Call once at startup; cheap when there is
    /// nothing to do.
    func backfillArtworkHashes() async {
        await self.artwork.backfillArtworkHashes(repo: self.podcastRepo)
    }

    /// Best-effort batch refresh. Feeds that fail are logged per-feed and do not
    /// interrupt the remaining batch.
    func refreshAllStale(olderThan: TimeInterval = 3600) async {
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
            if Task.isCancelled {
                return
            }
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
}

// MARK: - Refresh helpers

extension PodcastService {
    /// Applies a show's retention limit, best-effort: never throws so it cannot
    /// fail a subscribe/refresh. Nil limit is a no-op (keep all).
    func applyRetention(podcastID: Int64, keepNewest: Int?) async {
        guard keepNewest != nil else { return }
        do {
            try await self.podcastRepo.pruneEpisodes(podcastID: podcastID, keepNewest: keepNewest)
        } catch {
            self.log.debug("podcast.prune.failed", ["id": podcastID, "error": String(reflecting: error)])
        }
    }

    /// The conditional GET of a refresh. A failure is stamped on the row for
    /// display and then rethrown.
    private func fetchForRefresh(_ podcast: Podcast, feedURL: URL, podcastID: Int64) async throws -> FeedFetchResult {
        do {
            return try await self.fetcher.fetch(
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
    }

    /// The 304 path of a refresh: stamps the refresh time, clears any previous
    /// error and self-heals a missing cover image.
    private func stampNotModified(_ podcast: Podcast, podcastID: Int64) async throws -> RefreshOutcome {
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
}
