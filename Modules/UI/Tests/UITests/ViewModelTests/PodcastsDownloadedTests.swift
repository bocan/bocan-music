import Foundation
import Persistence
import Testing
@testable import UI

// MARK: - Doubles

/// A library with fixed shows and one fixed downloads emission.
private final class DownloadsLibrary: PodcastLibraryDataSource, @unchecked Sendable {
    var podcasts: [Podcast] = []
    var downloads: [EpisodeListItem] = []

    func subscribedPodcasts() async throws -> [Podcast] {
        self.podcasts
    }

    func episodes(podcastID _: Int64) async throws -> [EpisodeListItem] {
        []
    }

    func episodes(podcastID _: Int64, order _: EpisodeSortOrder) async throws -> [EpisodeListItem] {
        []
    }

    func observeSubscribed() async -> AsyncThrowingStream<[Podcast], Error> {
        AsyncThrowingStream { _ in }
    }

    func observeEpisodes(podcastID _: Int64) async -> AsyncThrowingStream<[EpisodeListItem], Error> {
        AsyncThrowingStream { _ in }
    }

    func observeEpisodes(
        podcastID _: Int64,
        order _: EpisodeSortOrder
    ) async -> AsyncThrowingStream<[EpisodeListItem], Error> {
        AsyncThrowingStream { _ in }
    }

    func episodeCounts() async throws -> [Int64: Int] {
        [:]
    }

    func unplayedCounts() async throws -> [Int64: Int] {
        [:]
    }

    func observeUnplayedCounts() async -> AsyncThrowingStream<[Int64: Int], Error> {
        AsyncThrowingStream { _ in }
    }

    func continueListening() async throws -> [ContinueListeningItem] {
        []
    }

    func observeContinueListening() async -> AsyncThrowingStream<[ContinueListeningItem], Error> {
        AsyncThrowingStream { _ in }
    }

    /// One emission, then the stream finishes, so `observeDownloaded()` returns.
    func observeDownloadedEpisodes() async -> AsyncThrowingStream<[EpisodeListItem], Error> {
        let value = self.downloads
        return AsyncThrowingStream {
            $0.yield(value)
            $0.finish()
        }
    }
}

/// Records each `enqueue` call; everything else does nothing.
private final class EnqueueRecorder: PodcastActions, @unchecked Sendable {
    struct Call {
        let guids: [String]
        let showIDs: Set<Int64>
        let placement: PodcastQueuePlacement
    }

    private(set) var calls: [Call] = []

    func enqueue(_ episodes: [EpisodeListItem], shows: [Int64: Podcast], placement: PodcastQueuePlacement) async {
        self.calls.append(Call(guids: episodes.map(\.episode.guid), showIDs: Set(shows.keys), placement: placement))
    }

    @discardableResult
    func subscribe(feedURL _: URL, podcastIndexID _: Int?, itunesCollectionID _: Int?) async throws -> Int64 {
        0
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
    func markPlayed(podcastID _: Int64, guids _: [String]) async {}
    func markUnplayed(podcastID _: Int64, guids _: [String]) async {}
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

// MARK: - Helpers

private func show(_ id: Int64, _ title: String) -> Podcast {
    var podcast = Podcast(feedURL: "https://example.com/\(id).xml", title: title, addedAt: 0)
    podcast.id = id
    return podcast
}

private func download(
    _ id: Int64,
    show: Int64,
    publishedAt: Double,
    playState: EpisodePlayState = .unplayed
) -> EpisodeListItem {
    var episode = PodcastEpisode(
        podcastID: show,
        guid: "g\(id)",
        title: "Episode \(id)",
        audioURL: "https://example.com/\(id).mp3",
        publishedAt: publishedAt,
        addedAt: 0
    )
    episode.id = id
    let state = PodcastEpisodeState(
        podcastID: show,
        guid: "g\(id)",
        playState: playState,
        downloadState: .downloaded,
        downloadBytes: 1000
    )
    return EpisodeListItem(episode: episode, state: state)
}

// MARK: - PodcastsDownloadedTests

/// The Downloaded list's arrangement and its Up Next actions (#651).
@Suite("Podcasts Downloaded list")
@MainActor
struct PodcastsDownloadedTests {
    /// Newest first, as the repository returns them: two shows interleaved.
    private let items = [
        download(4, show: 2, publishedAt: 400),
        download(3, show: 1, publishedAt: 300, playState: .played),
        download(2, show: 2, publishedAt: 200, playState: .inProgress),
        download(1, show: 1, publishedAt: 100),
    ]
    private let titles: [Int64: String] = [1: "Zebra Talk", 2: "Apple News"]

    @Test("The show filter keeps one show, and the query matches show titles too")
    func filtersByShowAndQuery() {
        let oneShow = PodcastsViewModel.visibleDownloads(
            self.items, showFilter: 1, query: "", order: .newest, showTitles: self.titles
        )
        #expect(oneShow.map(\.id) == [3, 1])

        let byShowTitle = PodcastsViewModel.visibleDownloads(
            self.items, showFilter: nil, query: " apple ", order: .newest, showTitles: self.titles
        )
        #expect(byShowTitle.map(\.id) == [4, 2])
    }

    @Test("Oldest first reverses the newest-first list")
    func oldestFirstReverses() {
        let oldest = PodcastsViewModel.visibleDownloads(
            self.items, showFilter: nil, query: "", order: .oldest, showTitles: self.titles
        )
        #expect(oldest.map(\.id) == [1, 2, 3, 4])
    }

    @Test("Grouping puts shows in title order and keeps each show's list order")
    func groupsByShowTitle() {
        let groups = PodcastsViewModel.groupedDownloads(self.items, showTitles: self.titles)
        #expect(groups.map(\.title) == ["Apple News", "Zebra Talk"])
        #expect(groups.map { $0.items.map(\.id) } == [[4, 2], [3, 1]])
    }

    @Test("Play All replaces Up Next with the unfinished episodes, in list order")
    func playAllSkipsPlayed() async {
        let library = DownloadsLibrary()
        library.podcasts = [show(1, "Zebra Talk"), show(2, "Apple News")]
        let actions = EnqueueRecorder()
        let vm = PodcastsViewModel(library: library, actions: actions)
        await vm.loadSubscribed()

        await vm.playAll(self.items)

        let call = actions.calls.first
        #expect(actions.calls.count == 1)
        #expect(call?.placement == .now)
        #expect(call?.guids == ["g4", "g2", "g1"], "the played episode is left out; in-progress stays")
        #expect(call?.showIDs == [1, 2], "every subscribed show is offered as a play target")
    }

    @Test("Play Next and Add to Queue pass the selection through in order")
    func queuePlacementsPassThrough() async {
        let library = DownloadsLibrary()
        library.podcasts = [show(1, "Zebra Talk"), show(2, "Apple News")]
        let actions = EnqueueRecorder()
        let vm = PodcastsViewModel(library: library, actions: actions)
        await vm.loadSubscribed()

        await vm.enqueue([self.items[2], self.items[0]], placement: .next)
        await vm.enqueue([self.items[1]], placement: .last)

        #expect(actions.calls.map(\.placement) == [.next, .last])
        #expect(actions.calls.map(\.guids) == [["g2", "g4"], ["g3"]])
    }

    @Test("The observation fills the list and the show filter's choices")
    func observationFillsList() async {
        let library = DownloadsLibrary()
        library.podcasts = [show(1, "Zebra Talk"), show(2, "Apple News"), show(3, "No Downloads Here")]
        library.downloads = self.items
        let vm = PodcastsViewModel(library: library, actions: nil)
        await vm.loadSubscribed()

        await vm.observeDownloaded()

        #expect(vm.downloaded.map(\.id) == [4, 3, 2, 1])
        #expect(vm.showsWithDownloads.map(\.title) == ["Apple News", "Zebra Talk"])
    }

    @Test("Go to Show from the Downloaded list backs out to that list")
    func showBacksOutToDownloads() {
        #expect(LibraryViewModel.isPlausibleContainer(.podcastDownloads, of: .podcastShow(1)))
        #expect(LibraryViewModel.isPlausibleContainer(.podcasts, of: .podcastShow(1)))
    }
}
