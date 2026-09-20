import Foundation
import Persistence
import Testing
@testable import UI

// MARK: - PodcastDownloadProgressTests

/// #551: `EpisodeDownloadManager.progress` had no consumer, so a large episode
/// showed "Downloading" with no idea how far it had got. The seam now carries
/// the fraction to `PodcastsViewModel`, which the episode badge reads.
@Suite("Podcast download progress (#551)")
@MainActor
struct PodcastDownloadProgressTests {
    /// Feeds the seam by hand, standing in for the download manager.
    private final class ProgressActions: PodcastActions, @unchecked Sendable {
        private let continuation: AsyncStream<UIEpisodeDownloadProgress>.Continuation
        private let stream: AsyncStream<UIEpisodeDownloadProgress>
        private(set) var subscribeCount = 0

        init() {
            (self.stream, self.continuation) = AsyncStream.makeStream(of: UIEpisodeDownloadProgress.self)
        }

        func send(_ event: UIEpisodeDownloadProgress) {
            self.continuation.yield(event)
        }

        func downloadProgress() async -> AsyncStream<UIEpisodeDownloadProgress> {
            self.subscribeCount += 1
            return self.stream
        }

        @discardableResult
        func subscribe(feedURL _: URL, podcastIndexID _: Int?, itunesCollectionID _: Int?) async throws -> Int64 {
            1
        }

        func unsubscribe(podcastID _: Int64) async throws {}
        func refresh(podcastID _: Int64) async throws {}
        func refreshAll() async {}
        func setAutoDownload(_: Bool, podcastID _: Int64) async throws {}
        func setPlaybackSpeed(_: Double?, podcastID _: Int64) async throws {}
        func setEpisodeSort(_: String?, podcastID _: Int64) async throws {}
        func setRetentionLimit(_: Int?, podcastID _: Int64) async throws {}
        func play(episode _: EpisodeListItem, podcast _: Podcast) async {}
        func markPlayed(podcastID _: Int64, guid _: String) async {}
        func markUnplayed(podcastID _: Int64, guid _: String) async {}
        func markAllPlayed(podcastID _: Int64) async {}
        func download(podcastID _: Int64, guid _: String) async {}
        func removeDownload(podcastID _: Int64, guid _: String) async {}
        func chapters(podcastID _: Int64, guid _: String) async throws -> [UIChapter] {
            []
        }

        func importOPML(
            data _: Data,
            progress _: @escaping @Sendable (Int, Int) -> Void
        ) async throws -> UIOPMLImportSummary {
            UIOPMLImportSummary()
        }

        func exportOPML() async throws -> Data {
            Data()
        }
    }

    /// A library with nothing in it: these tests drive the progress seam only.
    private struct EmptyLibrary: PodcastLibraryDataSource {
        func subscribedPodcasts() async throws -> [Podcast] {
            []
        }

        func episodes(podcastID _: Int64) async throws -> [EpisodeListItem] {
            []
        }

        func episodes(podcastID _: Int64, order _: EpisodeSortOrder) async throws -> [EpisodeListItem] {
            []
        }

        func observeSubscribed() async -> AsyncThrowingStream<[Podcast], Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func observeEpisodes(podcastID _: Int64) async -> AsyncThrowingStream<[EpisodeListItem], Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func observeEpisodes(
            podcastID _: Int64,
            order _: EpisodeSortOrder
        ) async -> AsyncThrowingStream<[EpisodeListItem], Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func episodeCounts() async throws -> [Int64: Int] {
            [:]
        }

        func unplayedCounts() async throws -> [Int64: Int] {
            [:]
        }

        func observeUnplayedCounts() async -> AsyncThrowingStream<[Int64: Int], Error> {
            AsyncThrowingStream { $0.finish() }
        }

        func continueListening() async throws -> [ContinueListeningItem] {
            []
        }

        func observeContinueListening() async -> AsyncThrowingStream<[ContinueListeningItem], Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    private func makeViewModel(_ actions: ProgressActions) async -> PodcastsViewModel {
        let vm = PodcastsViewModel(library: EmptyLibrary(), actions: actions)
        await vm.loadSubscribed()
        return vm
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async {
        for _ in 0 ..< 100 where !condition() {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private let key = PodcastsViewModel.downloadKey(podcastID: 7, guid: "ep-1")

    private func event(_ fraction: Double, _ status: EpisodeDownloadState) -> UIEpisodeDownloadProgress {
        UIEpisodeDownloadProgress(podcastID: 7, guid: "ep-1", fractionComplete: fraction, status: status)
    }

    @Test("a running download's fraction reaches the view model")
    func fractionArrives() async {
        let actions = ProgressActions()
        let vm = await self.makeViewModel(actions)
        #expect(vm.downloadProgress.isEmpty, "nothing is downloading yet")

        actions.send(self.event(0.42, .downloading))
        await self.waitUntil { vm.downloadProgress[self.key] != nil }
        #expect(vm.downloadProgress[self.key] == 0.42)

        actions.send(self.event(0.9, .downloading))
        await self.waitUntil { vm.downloadProgress[self.key] == 0.9 }
        #expect(vm.downloadProgress[self.key] == 0.9)
    }

    @Test("a finished download drops out, so no part-filled ring is left behind")
    func finishedDownloadIsRemoved() async {
        let actions = ProgressActions()
        let vm = await self.makeViewModel(actions)

        actions.send(self.event(0.8, .downloading))
        await self.waitUntil { vm.downloadProgress[self.key] != nil }

        actions.send(self.event(1.0, .downloaded))
        await self.waitUntil { vm.downloadProgress[self.key] == nil }
        #expect(vm.downloadProgress[self.key] == nil, "the persisted state carries a finished download")
    }

    @Test("a failed download drops out too")
    func failedDownloadIsRemoved() async {
        let actions = ProgressActions()
        let vm = await self.makeViewModel(actions)

        actions.send(self.event(0.3, .downloading))
        await self.waitUntil { vm.downloadProgress[self.key] != nil }

        actions.send(self.event(0.3, .failed))
        await self.waitUntil { vm.downloadProgress[self.key] == nil }
        #expect(vm.downloadProgress[self.key] == nil)
    }

    /// The seam is backed by one `AsyncStream`, so a second subscriber would
    /// divide the elements with the first (the #545 defect).
    @Test("the view model subscribes exactly once, however often it loads")
    func subscribesOnce() async {
        let actions = ProgressActions()
        let vm = await self.makeViewModel(actions)
        await vm.loadSubscribed()
        await vm.loadSubscribed()
        #expect(actions.subscribeCount == 1)
    }

    @Test("the status label carries the percentage while downloading")
    func statusLabelShowsPercentage() {
        let item = EpisodeListItem(
            episode: PodcastEpisode(
                podcastID: 7,
                guid: "ep-1",
                title: "Episode",
                audioURL: "https://a.test/1.mp3",
                addedAt: 0
            ),
            state: PodcastEpisodeState(podcastID: 7, guid: "ep-1", downloadState: .downloading)
        )
        #expect(statusLabel(item, downloadFraction: 0.42).contains("42"))
        // Before the first tick there is no percentage to show.
        #expect(!statusLabel(item, downloadFraction: nil).contains("%"))
    }
}
