import Foundation
import Playback
import Podcasts

/// Adapts `PodcastService` to `Playback`'s `PodcastEpisodeResolving` protocol,
/// so `QueuePlayer` can play a `.podcast` `PlayableSource` without the
/// `Playback` module importing `Podcasts`. Built once at app launch and
/// injected into `QueuePlayer`, mirroring `SubsonicStreamResolver`.
struct AppPodcastResolver: PodcastEpisodeResolving {
    let service: PodcastService

    func audioURL(feedURL: URL, episodeGUID: String) async throws -> URL {
        try await self.service.audioURL(feedURL: feedURL, episodeGUID: episodeGUID)
    }

    func resumePosition(feedURL: URL, episodeGUID: String) async -> TimeInterval {
        await self.service.resumePosition(feedURL: feedURL, episodeGUID: episodeGUID)
    }

    func persistPosition(
        feedURL: URL,
        episodeGUID: String,
        position: TimeInterval,
        duration: TimeInterval
    ) async {
        await self.service.saveProgress(
            feedURL: feedURL,
            episodeGUID: episodeGUID,
            position: position,
            duration: duration
        )
    }

    func markPlayed(feedURL: URL, episodeGUID: String) async {
        await self.service.markPlayed(feedURL: feedURL, episodeGUID: episodeGUID)
    }
}
