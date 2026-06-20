import Foundation
import Persistence
import Testing
@testable import UI

// MARK: - Stubs

/// Stub search provider whose `search` and `detail` outcomes can be configured per-test.
private final class StubSearchProvider: PodcastSearchProviding, @unchecked Sendable {
    enum Outcome {
        case success([UIPodcastSearchResult])
        case failure(Error)
        case sleep(Duration, [UIPodcastSearchResult])
    }

    var searchOutcome: Outcome = .success([])
    var detailOutcome: Result<PodcastDetail, Error>
    var searchCallCount = 0

    init(detail: PodcastDetail? = nil) {
        let defaultURL = URL(string: "https://example.com/feed") ?? URL(filePath: "/")
        self.detailOutcome = .success(
            detail ?? PodcastDetail(feedURL: defaultURL, title: "Show")
        )
    }

    func search(term: String) async throws -> [UIPodcastSearchResult] {
        self.searchCallCount += 1
        switch self.searchOutcome {
        case let .success(results):
            return results

        case let .failure(err):
            throw err

        case let .sleep(duration, results):
            try await Task.sleep(for: duration)
            return results
        }
    }

    func detail(feedURL: URL, hint: UIPodcastSearchResult?) async throws -> PodcastDetail {
        try self.detailOutcome.get()
    }
}

/// Convenience factory: one result pointed at the given URL.
private func makeResult(
    key: String = "example.com/feed",
    url: String = "https://example.com/feed",
    title: String = "Test Podcast"
) -> UIPodcastSearchResult {
    UIPodcastSearchResult(
        canonicalFeedKey: key,
        feedURL: URL(string: url) ?? URL(filePath: "/"),
        title: title,
        sources: [.itunes]
    )
}

// MARK: - PodcastsViewModelSearchTests

@Suite("PodcastsViewModel Search Tests")
@MainActor
struct PodcastsViewModelSearchTests {
    // MARK: - onAddBarTextChanged: URL detection

    @Test("http URL sets addByURLCandidate")
    func httpURLSetsCandidate() async {
        let stub = StubSearchProvider()
        stub.searchOutcome = .success([])
        let vm = PodcastsViewModel(library: nil, actions: nil, searchProvider: stub)
        await vm.onAddBarTextChanged("http://feeds.example.com/podcast")
        #expect(vm.addByURLCandidate?.absoluteString == "http://feeds.example.com/podcast")
    }

    @Test("https URL sets addByURLCandidate")
    func httpsURLSetsCandidate() async {
        let stub = StubSearchProvider()
        stub.searchOutcome = .success([makeResult()])
        let vm = PodcastsViewModel(library: nil, actions: nil, searchProvider: stub)
        await vm.onAddBarTextChanged("https://example.com/feed")
        #expect(vm.addByURLCandidate != nil)
    }

    @Test("Non-URL text clears addByURLCandidate")
    func plainTextClearsCandidate() async throws {
        let stub = StubSearchProvider()
        let vm = PodcastsViewModel(library: nil, actions: nil, searchProvider: stub)
        vm.addByURLCandidate = try #require(URL(string: "https://old.example.com"))
        await vm.onAddBarTextChanged("science fiction")
        #expect(vm.addByURLCandidate == nil)
    }

    // MARK: - onAddBarTextChanged: empty / whitespace

    @Test("Empty text transitions to idle and clears results")
    func emptyTextGoesToIdle() async {
        let stub = StubSearchProvider()
        stub.searchOutcome = .success([makeResult()])
        let vm = PodcastsViewModel(library: nil, actions: nil, searchProvider: stub)
        await vm.onAddBarTextChanged("something")
        #expect(vm.searchState == .results)
        await vm.onAddBarTextChanged("")
        #expect(vm.searchState == .idle)
        #expect(vm.searchResults.isEmpty)
    }

    @Test("Whitespace-only text transitions to idle")
    func whitespaceGoesToIdle() async {
        let stub = StubSearchProvider()
        let vm = PodcastsViewModel(library: nil, actions: nil, searchProvider: stub)
        await vm.onAddBarTextChanged("   ")
        #expect(vm.searchState == .idle)
    }

    // MARK: - onAddBarTextChanged: successful search

    @Test("Successful search with results transitions to .results")
    func successfulSearchWithResults() async {
        let stub = StubSearchProvider()
        stub.searchOutcome = .success([makeResult(key: "a/b", title: "Show A"), makeResult(key: "c/d", title: "Show B")])
        let vm = PodcastsViewModel(library: nil, actions: nil, searchProvider: stub)
        await vm.onAddBarTextChanged("science")
        #expect(vm.searchState == .results)
        #expect(vm.searchResults.count == 2)
        #expect(stub.searchCallCount == 1)
    }

    @Test("Successful search with empty results transitions to .empty")
    func successfulSearchEmpty() async {
        let stub = StubSearchProvider()
        stub.searchOutcome = .success([])
        let vm = PodcastsViewModel(library: nil, actions: nil, searchProvider: stub)
        await vm.onAddBarTextChanged("xyzzy-no-results")
        #expect(vm.searchState == .empty)
        #expect(vm.searchResults.isEmpty)
    }

    // MARK: - onAddBarTextChanged: error

    @Test("Search failure transitions to .error")
    func searchFailureGoesToError() async {
        let stub = StubSearchProvider()
        stub.searchOutcome = .failure(URLError(.notConnectedToInternet))
        let vm = PodcastsViewModel(library: nil, actions: nil, searchProvider: stub)
        await vm.onAddBarTextChanged("anything")
        guard case .error = vm.searchState else {
            Issue.record("Expected .error, got \(vm.searchState)")
            return
        }
    }

    // MARK: - onAddBarTextChanged: nil provider

    @Test("Nil search provider leaves state idle and does not search")
    func nilProviderNoChange() async {
        let vm = PodcastsViewModel(library: nil, actions: nil, searchProvider: nil)
        await vm.onAddBarTextChanged("hello")
        #expect(vm.searchState == .idle)
        #expect(vm.searchResults.isEmpty)
    }

    // MARK: - retrySearch

    @Test("retrySearch re-runs the current addBarText search")
    func retrySearch() async {
        let stub = StubSearchProvider()
        stub.searchOutcome = .success([makeResult()])
        let vm = PodcastsViewModel(library: nil, actions: nil, searchProvider: stub)
        vm.addBarText = "yoga"
        await vm.onAddBarTextChanged("yoga")
        let callsBefore = stub.searchCallCount
        await vm.retrySearch()
        #expect(stub.searchCallCount == callsBefore + 1)
    }

    // MARK: - dismissDetail

    @Test("dismissDetail resets all detail state")
    func dismissDetail() throws {
        let stub = StubSearchProvider()
        let vm = PodcastsViewModel(library: nil, actions: nil, searchProvider: stub)
        vm.showingDetail = true
        vm.isLoadingDetail = true
        vm.currentDetail = try PodcastDetail(feedURL: #require(URL(string: "https://x.com")), title: "X")
        vm.detailError = "oops"
        vm.dismissDetail()
        #expect(!vm.showingDetail)
        #expect(!vm.isLoadingDetail)
        #expect(vm.currentDetail == nil)
        #expect(vm.detailError == nil)
    }

    // MARK: - openDetail

    @Test("openDetail sets showingDetail = true immediately")
    func openDetailImmediateState() async {
        let stub = StubSearchProvider()
        let vm = PodcastsViewModel(library: nil, actions: nil, searchProvider: stub)
        let result = makeResult()
        await vm.openDetail(result)
        // showingDetail is set synchronously before the fetch task; isLoadingDetail may still be true.
        #expect(vm.showingDetail)
    }

    @Test("openDetail populates currentDetail on success")
    func openDetailPopulates() async throws {
        let feedURL = try #require(URL(string: "https://example.com/feed"))
        let stub = StubSearchProvider(detail: PodcastDetail(feedURL: feedURL, title: "Good Show"))
        let vm = PodcastsViewModel(library: nil, actions: nil, searchProvider: stub)
        await vm.openDetail(makeResult())
        await vm.detailTask?.value
        #expect(vm.currentDetail?.title == "Good Show")
        #expect(!vm.isLoadingDetail)
    }

    @Test("openDetail sets detailError on failure")
    func openDetailError() async {
        let stub = StubSearchProvider()
        stub.detailOutcome = .failure(URLError(.badServerResponse))
        let vm = PodcastsViewModel(library: nil, actions: nil, searchProvider: stub)
        await vm.openDetail(makeResult())
        await vm.detailTask?.value
        #expect(vm.detailError != nil)
        #expect(!vm.isLoadingDetail)
    }

    // MARK: - subscribe

    @Test("subscribe flips alreadySubscribed on the current detail")
    func subscribeFlipsFlag() async throws {
        let feedURL = try #require(URL(string: "https://example.com/feed"))
        let stub = StubSearchProvider(detail: PodcastDetail(feedURL: feedURL, title: "Show"))

        struct StubActions: PodcastActions, @unchecked Sendable {
            func subscribe(feedURL: URL) async throws -> Int64 {
                42
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
        }

        let vm = PodcastsViewModel(library: nil, actions: StubActions(), searchProvider: stub)
        let detail = PodcastDetail(feedURL: feedURL, title: "Show")
        vm.currentDetail = detail
        await vm.subscribe(fromDetail: detail)
        #expect(vm.currentDetail?.alreadySubscribed == true)
        #expect(vm.currentDetail?.podcastID == 42)
    }
}
