import Foundation
import Persistence

// MARK: - PodcastLibraryDataSource

/// Data-access protocol the UI uses to read podcast library state.
///
/// Declared in the UI module so UI never imports `Podcasts`. The App layer
/// conforms `PodcastService` to this protocol and injects it into
/// `LibraryViewModel`. Seam types (`Podcast`, `EpisodeListItem`) come from
/// `Persistence`, which UI already imports.
public protocol PodcastLibraryDataSource: Sendable {
    func subscribedPodcasts() async throws -> [Podcast]
    func episodes(podcastID: Int64) async throws -> [EpisodeListItem]
    func observeSubscribed() async -> AsyncThrowingStream<[Podcast], Error>
    func observeEpisodes(podcastID: Int64) async -> AsyncThrowingStream<[EpisodeListItem], Error>
}

// MARK: - PodcastActions

/// Mutation protocol the UI uses to drive podcast operations.
///
/// Declared in the UI module so UI never imports `Podcasts`. The App layer
/// implements `AppPodcastActions` over `PodcastService` + `QueuePlayer`.
///
/// `play(episode:podcast:)` lives in the App implementation because building a
/// podcast `QueueItem` requires both `PlayableSource.podcast` (from Playback)
/// and the `QueuePlayer` (also in Playback) -- two lower modules UI must not
/// see together.
public protocol PodcastActions: Sendable {
    @discardableResult func subscribe(feedURL: URL) async throws -> Int64
    func unsubscribe(podcastID: Int64) async throws
    func refresh(podcastID: Int64) async throws
    func refreshAll() async
    func reorder(podcastIDs: [Int64]) async throws
    func setAutoDownload(_ on: Bool, podcastID: Int64) async throws
    /// Builds and enqueues a podcast `QueueItem`, then begins playback.
    func play(episode: EpisodeListItem, podcast: Podcast) async
    func markPlayed(podcastID: Int64, guid: String) async
    func markUnplayed(podcastID: Int64, guid: String) async
    /// No-op when phase 21-6 downloads are not built.
    func download(podcastID: Int64, guid: String) async
    func removeDownload(podcastID: Int64, guid: String) async
}
