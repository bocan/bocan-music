import Foundation
import Observability
import Persistence

/// Decides which freshly discovered episodes to auto-download after a refresh,
/// keeping that policy out of the bare `EpisodeDownloadManager`.
///
/// When a show has `auto_download` enabled, the newest `newestN` episodes that
/// are not already downloaded or played are enqueued. The App layer (phase 21-4
/// refresh / scheduler) calls `handleRefresh` with the `RefreshOutcome`.
public struct AutoDownloadCoordinator: Sendable {
    private let podcastRepo: PodcastRepository
    private let episodeRepo: EpisodeRepository
    private let stateRepo: EpisodeStateRepository
    private let manager: EpisodeDownloadManager
    private let newestN: Int
    private let log = AppLogger.make(.podcasts)

    public init(
        podcastRepo: PodcastRepository,
        episodeRepo: EpisodeRepository,
        stateRepo: EpisodeStateRepository,
        manager: EpisodeDownloadManager,
        newestN: Int = 3
    ) {
        self.podcastRepo = podcastRepo
        self.episodeRepo = episodeRepo
        self.stateRepo = stateRepo
        self.manager = manager
        self.newestN = max(0, newestN)
    }

    /// Enqueue the newest qualifying episodes for an auto-download show after a
    /// refresh found new episodes. A no-op when the show is not auto-download or
    /// the refresh added nothing.
    public func handleRefresh(podcastID: Int64, outcome: RefreshOutcome) async {
        guard !outcome.newEpisodeGUIDs.isEmpty, self.newestN > 0 else { return }

        let podcast: Podcast
        do {
            podcast = try await self.podcastRepo.fetch(id: podcastID)
        } catch {
            self.log.warning(
                "autoDownload.fetchPodcastFailed",
                ["podcastID": podcastID, "error": String(reflecting: error)]
            )
            return
        }
        guard podcast.autoDownload else { return }

        let newGUIDs = Set(outcome.newEpisodeGUIDs)
        let episodes: [PodcastEpisode]
        do {
            // Newest first; the manager orders downloads by this list.
            episodes = try await self.episodeRepo.fetchForPodcast(podcastID: podcastID)
        } catch {
            self.log.warning(
                "autoDownload.fetchEpisodesFailed",
                ["podcastID": podcastID, "error": String(reflecting: error)]
            )
            return
        }

        var enqueued = 0
        for episode in episodes where newGUIDs.contains(episode.guid) {
            if enqueued >= self.newestN { break }
            let state = try? await self.stateRepo.fetch(podcastID: podcastID, guid: episode.guid)
            if let state, state.downloadState == .downloaded || state.playState == .played {
                continue // already downloaded or already heard
            }
            await self.manager.download(podcastID: podcastID, guid: episode.guid)
            enqueued += 1
        }
        self.log.debug("autoDownload.enqueued", ["podcastID": podcastID, "count": enqueued])
    }
}
