import Foundation
import Persistence
import Playback
import Podcasts
import UI

// MARK: - PodcastService: PodcastLibraryDataSource

/// Empty conformance: the four required methods have the same signatures
/// in both the protocol and `PodcastService`, so no implementation body is
/// needed.
extension PodcastService: @retroactive PodcastLibraryDataSource {}

// MARK: - AppPodcastActions

/// Concrete `PodcastActions` adapter that bridges the UI seam to the real
/// `Podcasts` and `Playback` modules. Constructed once in `buildGraph` and
/// injected into `LibraryViewModel`.
struct AppPodcastActions: PodcastActions {
    let service: PodcastService
    let player: QueuePlayer
    let downloads: EpisodeDownloadManager?

    func subscribe(feedURL: URL) async throws -> Int64 {
        try await self.service.subscribe(feedURL: feedURL)
    }

    func unsubscribe(podcastID: Int64) async throws {
        try await self.service.unsubscribe(podcastID: podcastID)
    }

    func refresh(podcastID: Int64) async throws {
        _ = try await self.service.refresh(podcastID: podcastID)
    }

    func refreshAll() async {
        await self.service.refreshAllStale()
    }

    func reorder(podcastIDs: [Int64]) async throws {
        try await self.service.reorder(podcastIDs: podcastIDs)
    }

    func setAutoDownload(_ on: Bool, podcastID: Int64) async throws {
        try await self.service.setAutoDownload(on, podcastID: podcastID)
    }

    /// Builds a podcast `QueueItem` and hands it to `QueuePlayer.play(items:)`.
    ///
    /// Source format fields are intentionally generic: the real format is
    /// sniffed when `QueuePlayer` resolves the `.podcast` source via
    /// `AppPodcastResolver`; the values here only gate gapless compatibility
    /// checks, which don't apply to podcast episodes.
    func play(episode: EpisodeListItem, podcast: Podcast) async {
        guard let feedURL = URL(string: podcast.feedURL) else { return }
        let source = PlayableSource.podcast(feedURL: feedURL, episodeGUID: episode.episode.guid)
        let item = QueueItem(
            trackID: -1,
            bookmark: nil,
            fileURL: "",
            duration: episode.episode.duration ?? 0,
            sourceFormat: AudioSourceFormat(
                sampleRate: 44100,
                bitDepth: 16,
                channelCount: 2,
                isInterleaved: false,
                codec: "mp3"
            ),
            title: episode.episode.title,
            artistName: podcast.title,
            albumName: podcast.title,
            playableSource: source
        )
        do {
            try await self.player.play(items: [item], startingAt: 0)
        } catch {
            // QueuePlayer logs internally; swallowing here keeps PodcastActions non-throwing.
        }
    }

    func markPlayed(podcastID: Int64, guid: String) async {
        await self.service.markPlayed(podcastID: podcastID, guid: guid)
    }

    func markUnplayed(podcastID: Int64, guid: String) async {
        await self.service.markUnplayed(podcastID: podcastID, guid: guid)
    }

    func markAllPlayed(podcastID: Int64) async {
        await self.service.markAllPlayed(podcastID: podcastID)
    }

    func download(podcastID: Int64, guid: String) async {
        await self.downloads?.download(podcastID: podcastID, guid: guid)
    }

    func removeDownload(podcastID: Int64, guid: String) async {
        await self.downloads?.removeDownload(podcastID: podcastID, guid: guid)
    }
}
