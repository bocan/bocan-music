import Foundation
import Observability
import Persistence

// MARK: - Playback-state bridge

/// The playback bridge: the only code that writes `podcast_episode_state` play state.
public extension PodcastService {
    /// Returns the enclosure URL for an episode (or a local file URL when downloaded).
    func audioURL(feedURL: URL, episodeGUID: String) async throws -> URL {
        let podcastID = try await resolveID(feedURL: feedURL)
        guard let episode = try await episodeRepo.fetchByGUID(
            podcastID: podcastID,
            guid: episodeGUID
        ) else {
            throw PodcastsError.notFound(feedURL: feedURL)
        }

        // Episode-level art is fetched lazily, the first time an episode is
        // played, rather than for every episode of every feed (#410).
        self.kickEpisodeArtwork(episode: episode, podcastID: podcastID)

        // Return the downloaded file URL when available (ADR-043 populates this).
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
    func resumePosition(feedURL: URL, episodeGUID: String) async -> TimeInterval {
        do {
            let podcastID = try await resolveID(feedURL: feedURL)
            guard let state = try await stateRepo.fetch(podcastID: podcastID, guid: episodeGUID) else {
                return 0
            }
            if state.playState == .played {
                return 0
            }
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
    func saveProgress(
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
    func markPlayed(feedURL: URL, episodeGUID: String) async {
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
    func markUnplayed(feedURL: URL, episodeGUID: String) async {
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
    func markPlayed(podcastID: Int64, guid: String) async {
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
    func markUnplayed(podcastID: Int64, guid: String) async {
        do {
            try await self.stateRepo.markUnplayed(podcastID: podcastID, guid: guid)
        } catch {
            self.log.warning("podcast.markUnplayed.byID.failed", ["error": String(reflecting: error)])
        }
    }

    /// Marks all episodes for a podcast as played (UI seam).
    func markAllPlayed(podcastID: Int64) async {
        do {
            try await self.stateRepo.markAllPlayed(podcastID: podcastID, now: self.now().timeIntervalSince1970)
        } catch {
            self.log.warning("podcast.markAllPlayed.failed", ["error": String(reflecting: error)])
        }
    }
}
