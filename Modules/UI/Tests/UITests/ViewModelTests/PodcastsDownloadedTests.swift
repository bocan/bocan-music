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

    func episodes(podcastID: Int64) async throws -> [EpisodeListItem] {
        self.downloads.filter { $0.episode.podcastID == podcastID }
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

    /// Show notes by guid, served one at a time as the real read does.
    var notes: [String: String] = [:]

    func showNotesHTML(podcastID _: Int64, guid: String) async throws -> String? {
        self.notes[guid]
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

    private func visible(
        showFilter: Int64? = nil,
        query: String = "",
        sort: [KeyPathComparator<DownloadedRow>] = DownloadedSort.defaultOrder
    ) -> [DownloadedRow] {
        PodcastsViewModel.visibleDownloads(
            self.items, showFilter: showFilter, query: query, sortOrder: sort, showTitles: self.titles
        )
    }

    @Test("The show filter keeps one show, and the query matches show titles too")
    func filtersByShowAndQuery() {
        #expect(self.visible(showFilter: 1).map(\.id) == [3, 1])
        #expect(self.visible(query: " apple ").map(\.id) == [4, 2])
    }

    @Test("Each column heading sorts; a show sort keeps each show's episodes newest first")
    func columnsSort() {
        #expect(self.visible().map(\.id) == [4, 3, 2, 1], "newest first before any click")
        let oldest = DownloadedSort.order(from: "published.forward")
        #expect(self.visible(sort: oldest).map(\.id) == [1, 2, 3, 4])
        let byShow = DownloadedSort.order(from: "show.forward")
        #expect(self.visible(sort: byShow).map(\.id) == [4, 2, 3, 1], "ties keep the newest-first input order")
        let byTitleDown = DownloadedSort.order(from: "episode.reverse")
        #expect(self.visible(sort: byTitleDown).map(\.id) == [4, 3, 2, 1])
    }

    @Test("The stored sort string round-trips, and junk falls back to newest first")
    func sortRoundTrips() {
        for raw in ["episode.forward", "show.reverse", "published.forward", "length.reverse"] {
            #expect(DownloadedSort.rawValue(for: DownloadedSort.order(from: raw)) == raw)
        }
        #expect(DownloadedSort.rawValue(for: DownloadedSort.order(from: "")) == "published.reverse")
        #expect(DownloadedSort.rawValue(for: DownloadedSort.order(from: "tempo.up")) == "published.reverse")
    }

    @Test("Grouping puts shows in title order and keeps each show's list order")
    func groupsByShowTitle() {
        let groups = PodcastsViewModel.groupedDownloads(self.visible())
        #expect(groups.map(\.title) == ["Apple News", "Zebra Talk"])
        #expect(groups.map { $0.rows.map(\.id) } == [[4, 2], [3, 1]])
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

    @Test("Show notes the list rows leave out are read in for the notes sheets")
    func showNotesReadOnDemand() async {
        let library = DownloadsLibrary()
        library.podcasts = [show(1, "Zebra Talk"), show(2, "Apple News")]
        library.downloads = self.items
        library.notes = ["g3": "<p>Notes</p>"]
        let vm = PodcastsViewModel(library: library, actions: nil)

        let filled = await vm.withShowNotes(self.items[1])
        #expect(filled.episode.descriptionHTML == "<p>Notes</p>", "the show page's sheet gets the notes")
        #expect(await vm.showNotesHTML(for: self.items[0]) == nil, "an episode with no notes stays nil")

        await vm.loadNowPlayingShowNotes(podcastID: 1, guid: "g3")
        #expect(vm.nowPlayingEpisode?.episode.descriptionHTML == "<p>Notes</p>", "the player bar's sheet too")
    }

    @Test("Go to Show from the Downloaded list backs out to that list")
    func showBacksOutToDownloads() {
        #expect(LibraryViewModel.isPlausibleContainer(.podcastDownloads, of: .podcastShow(1)))
        #expect(LibraryViewModel.isPlausibleContainer(.podcasts, of: .podcastShow(1)))
    }
}
