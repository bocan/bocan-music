import Foundation
import Persistence
import Testing
@testable import UI

// MARK: - Stubs

/// In-process stub for `PodcastLibraryDataSource`. Returns whatever arrays are
/// set before the test, never hits the network or a database.
private final class StubPodcastLibrary: PodcastLibraryDataSource, @unchecked Sendable {
    var podcasts: [Podcast] = []
    var episodeItems: [EpisodeListItem] = []
    var unplayedCountsValue: [Int64: Int] = [:]
    var subscribedCalled = false
    var episodesCalled = false

    func subscribedPodcasts() async throws -> [Podcast] {
        self.subscribedCalled = true
        return self.podcasts
    }

    func episodes(podcastID: Int64) async throws -> [EpisodeListItem] {
        self.episodesCalled = true
        return self.episodeItems
    }

    func observeSubscribed() async -> AsyncThrowingStream<[Podcast], Error> {
        AsyncThrowingStream { _ in }
    }

    func observeEpisodes(podcastID: Int64) async -> AsyncThrowingStream<[EpisodeListItem], Error> {
        AsyncThrowingStream { _ in }
    }

    func episodeCounts() async throws -> [Int64: Int] {
        [:]
    }

    func unplayedCounts() async throws -> [Int64: Int] {
        self.unplayedCountsValue
    }

    func observeUnplayedCounts() async -> AsyncThrowingStream<[Int64: Int], Error> {
        AsyncThrowingStream { _ in }
    }
}

/// In-process stub for `PodcastActions`. Records calls; no-ops for everything.
private struct StubPodcastActions: PodcastActions, @unchecked Sendable {
    var subscribeCallCount = 0
    var refreshAllCallCount = 0

    @discardableResult
    func subscribe(feedURL: URL) async throws -> Int64 {
        1
    }

    func unsubscribe(podcastID: Int64) async throws {}
    func refresh(podcastID: Int64) async throws {}
    func refreshAll() async {}
    func reorder(podcastIDs: [Int64]) async throws {}
    func setAutoDownload(_ on: Bool, podcastID: Int64) async throws {}
    func play(episode: EpisodeListItem, podcast: Podcast) async {}
    func markPlayed(podcastID: Int64, guid: String) async {}
    func markUnplayed(podcastID: Int64, guid: String) async {}
    func markAllPlayed(podcastID: Int64) async {}
    func download(podcastID: Int64, guid: String) async {}
    func removeDownload(podcastID: Int64, guid: String) async {}
    func chapters(podcastID: Int64, guid: String) async throws -> [UIChapter] {
        []
    }

    func importOPML(data: Data, progress: @escaping @Sendable (Int, Int) -> Void) async throws -> UIOPMLImportSummary {
        UIOPMLImportSummary()
    }

    func exportOPML() async throws -> Data {
        Data()
    }
}

// MARK: - Helpers

private func makePodcast(id: Int64 = 1, title: String = "Test Show") -> Podcast {
    var podcast = Podcast(
        feedURL: "https://example.com/feed.xml",
        title: title,
        addedAt: 0
    )
    podcast.id = id
    return podcast
}

// MARK: - PodcastsViewModelTests

@Suite("PodcastsViewModel Tests")
@MainActor
struct PodcastsViewModelTests {
    // MARK: - Init

    @Test("Init with no seams leaves subscribed empty and isLoading false")
    func initWithNoSeams() {
        let vm = PodcastsViewModel(library: nil, actions: nil)
        #expect(vm.subscribed.isEmpty)
        #expect(!vm.isLoading)
        #expect(vm.currentShow == nil)
        #expect(vm.episodes.isEmpty)
        #expect(vm.addBarText.isEmpty)
        #expect(vm.selectedShowID == nil)
    }

    // MARK: - loadSubscribed

    @Test("loadSubscribed fetches shows from library seam")
    func loadSubscribedFetches() async {
        let lib = StubPodcastLibrary()
        lib.podcasts = [makePodcast(id: 1, title: "Show A"), makePodcast(id: 2, title: "Show B")]
        let vm = PodcastsViewModel(library: lib, actions: nil)
        await vm.loadSubscribed()
        #expect(vm.subscribed.count == 2)
        #expect(!vm.isLoading)
        #expect(lib.subscribedCalled)
    }

    @Test("loadSubscribed populates podcastUnplayedCounts from the library seam")
    func loadSubscribedPopulatesUnplayed() async {
        let lib = StubPodcastLibrary()
        lib.podcasts = [makePodcast(id: 1, title: "Show A")]
        lib.unplayedCountsValue = [1: 3]
        let vm = PodcastsViewModel(library: lib, actions: nil)
        await vm.loadSubscribed()
        #expect(vm.podcastUnplayedCounts[1] == 3)
    }

    @Test("loadSubscribed when library is nil leaves subscribed empty")
    func loadSubscribedNoLibrary() async {
        let vm = PodcastsViewModel(library: nil, actions: nil)
        await vm.loadSubscribed()
        #expect(vm.subscribed.isEmpty)
        #expect(!vm.isLoading)
    }

    @Test("loadSubscribed when library throws leaves subscribed unchanged")
    func loadSubscribedThrows() async {
        final class ThrowingLibrary: PodcastLibraryDataSource, @unchecked Sendable {
            func subscribedPodcasts() async throws -> [Podcast] {
                throw URLError(.badServerResponse)
            }

            func episodes(podcastID: Int64) async throws -> [EpisodeListItem] {
                []
            }

            func observeSubscribed() async -> AsyncThrowingStream<[Podcast], Error> {
                AsyncThrowingStream { _ in }
            }

            func observeEpisodes(podcastID: Int64) async -> AsyncThrowingStream<[EpisodeListItem], Error> {
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
        }
        let vm = PodcastsViewModel(library: ThrowingLibrary(), actions: nil)
        await vm.loadSubscribed()
        #expect(vm.subscribed.isEmpty)
        #expect(!vm.isLoading)
    }

    // MARK: - loadShow

    @Test("loadShow populates currentShow and episodes")
    func loadShowPopulates() async {
        let lib = StubPodcastLibrary()
        lib.podcasts = [makePodcast(id: 42, title: "My Show")]
        let vm = PodcastsViewModel(library: lib, actions: nil)
        await vm.loadShow(42)
        #expect(vm.currentShow?.title == "My Show")
        #expect(!vm.isLoading)
        #expect(lib.episodesCalled)
    }

    @Test("loadShow when podcastID not found leaves currentShow nil")
    func loadShowMissingID() async {
        let lib = StubPodcastLibrary()
        lib.podcasts = [makePodcast(id: 1, title: "A")]
        let vm = PodcastsViewModel(library: lib, actions: nil)
        await vm.loadShow(999)
        #expect(vm.currentShow == nil)
    }

    // MARK: - openShow

    @Test("openShow publishes selectedShowID")
    func openShowSetsID() {
        let vm = PodcastsViewModel(library: nil, actions: nil)
        #expect(vm.selectedShowID == nil)
        vm.openShow(7)
        #expect(vm.selectedShowID == 7)
    }

    // MARK: - OPML

    @Test("importOPML / exportOPML delegate to the actions seam")
    func opmlDelegatesToActions() async throws {
        struct OPMLStub: PodcastActions, @unchecked Sendable {
            @discardableResult func subscribe(feedURL: URL) async throws -> Int64 {
                1
            }

            func unsubscribe(podcastID: Int64) async throws {}
            func refresh(podcastID: Int64) async throws {}
            func refreshAll() async {}
            func reorder(podcastIDs: [Int64]) async throws {}
            func setAutoDownload(_ on: Bool, podcastID: Int64) async throws {}
            func play(episode: EpisodeListItem, podcast: Podcast) async {}
            func markPlayed(podcastID: Int64, guid: String) async {}
            func markUnplayed(podcastID: Int64, guid: String) async {}
            func markAllPlayed(podcastID: Int64) async {}
            func download(podcastID: Int64, guid: String) async {}
            func removeDownload(podcastID: Int64, guid: String) async {}
            func chapters(podcastID: Int64, guid: String) async throws -> [UIChapter] {
                []
            }

            func importOPML(
                data: Data,
                progress: @escaping @Sendable (Int, Int) -> Void
            ) async throws -> UIOPMLImportSummary {
                progress(1, 1)
                let url = URL(string: "https://a.example.com/feed") ?? URL(filePath: "/")
                return UIOPMLImportSummary(succeeded: [UIOPMLImportItem(title: "A", feedURL: url, reason: "Subscribed")])
            }

            func exportOPML() async throws -> Data {
                Data("opml".utf8)
            }
        }
        let vm = PodcastsViewModel(library: nil, actions: OPMLStub())
        let summary = try await vm.importOPML(data: Data()) { _, _ in }
        #expect(summary.succeeded.count == 1)
        let data = try await vm.exportOPML()
        #expect(!data.isEmpty)
    }

    @Test("importOPML with no actions seam returns an empty summary")
    func opmlNoActionsEmpty() async throws {
        let vm = PodcastsViewModel(library: nil, actions: nil)
        let summary = try await vm.importOPML(data: Data()) { _, _ in }
        #expect(summary.totalAttempted == 0)
    }

    // MARK: - addBarText

    @Test("addBarText starts empty and can be mutated")
    func addBarText() {
        let vm = PodcastsViewModel(library: nil, actions: nil)
        vm.addBarText = "hello"
        #expect(vm.addBarText == "hello")
    }
}
