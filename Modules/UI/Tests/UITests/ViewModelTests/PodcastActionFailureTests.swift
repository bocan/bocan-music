import Foundation
import Library
import Persistence
import Testing
@testable import UI

// MARK: - Stub

/// A `PodcastActions` whose play-state writes and download start fail for the
/// shows in `failingShows`, and work for every other show.
private final class FailingPodcastActions: PodcastActions, @unchecked Sendable {
    struct Failure: Error {}

    var failingShows: Set<Int64> = [1]
    private(set) var attempts = 0

    private func attempt(_ podcastID: Int64) throws {
        self.attempts += 1
        if self.failingShows.contains(podcastID) {
            throw Failure()
        }
    }

    func markPlayed(podcastID: Int64, guid: String) async throws {
        try self.attempt(podcastID)
    }

    func markUnplayed(podcastID: Int64, guid: String) async throws {
        try self.attempt(podcastID)
    }

    func markPlayed(podcastID: Int64, guids: [String]) async throws {
        try self.attempt(podcastID)
    }

    func markUnplayed(podcastID: Int64, guids: [String]) async throws {
        try self.attempt(podcastID)
    }

    func markAllPlayed(podcastID: Int64) async throws {
        try self.attempt(podcastID)
    }

    func download(podcastID: Int64, guid: String) async throws {
        try self.attempt(podcastID)
    }

    @discardableResult
    func subscribe(feedURL: URL, podcastIndexID: Int?, itunesCollectionID: Int?) async throws -> Int64 {
        0
    }

    func unsubscribe(podcastID: Int64) async throws {}
    func refresh(podcastID: Int64) async throws {}
    func refreshAll() async {}
    func setAutoDownload(_ on: Bool, podcastID: Int64) async throws {}
    func setPlaybackSpeed(_ speed: Double?, podcastID: Int64) async throws {}
    func setEpisodeSort(_ sort: String?, podcastID: Int64) async throws {}
    func setRetentionLimit(_ limit: Int?, podcastID: Int64) async throws {}
    func play(episode: EpisodeListItem, podcast: Podcast) async {}
    func removeDownload(podcastID: Int64, guid: String) async {}
    func chapters(podcastID: Int64, guid: String) async throws -> [UIChapter] {
        []
    }

    func importOPML(
        data: Data,
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> UIOPMLImportSummary {
        UIOPMLImportSummary()
    }

    func exportOPML() async throws -> Data {
        Data()
    }
}

// MARK: - Helpers

private func item(_ guid: String, podcastID: Int64) -> EpisodeListItem {
    EpisodeListItem(
        episode: PodcastEpisode(
            podcastID: podcastID,
            guid: guid,
            title: "Episode \(guid)",
            audioURL: "https://example.test/\(guid).mp3",
            addedAt: 0
        ),
        state: nil
    )
}

// MARK: - PodcastActionFailureTests

/// A podcast action that fails must reach the listener (#640). Before, the
/// seam could not throw, so a failed write was only logged: the list did not
/// change and Mark as Played or Download looked like it did nothing.
@Suite("Podcast action failure")
@MainActor
struct PodcastActionFailureTests {
    /// A view model over `actions` that records what it would tell the listener.
    private func makeVM(_ actions: FailingPodcastActions) -> (vm: PodcastsViewModel, messages: () -> [String]) {
        final class Box { var messages: [String] = [] }
        let box = Box()
        let vm = PodcastsViewModel(library: nil, actions: actions)
        vm.onActionFailed = { box.messages.append($0) }
        return (vm, { box.messages })
    }

    @Test("a failed Mark as Played tells the listener")
    func markPlayedFailure() async {
        let (vm, messages) = self.makeVM(FailingPodcastActions())
        await vm.markPlayed(podcastID: 1, guid: "a")
        #expect(messages() == ["Could not mark as played"])
    }

    @Test("a failed Mark as Unplayed tells the listener")
    func markUnplayedFailure() async {
        let (vm, messages) = self.makeVM(FailingPodcastActions())
        await vm.markUnplayed(podcastID: 1, guid: "a")
        #expect(messages() == ["Could not mark as unplayed"])
    }

    @Test("a selection that fails for one show still marks the other, and tells the listener once")
    func selectionFailure() async {
        let actions = FailingPodcastActions()
        let (vm, messages) = self.makeVM(actions)
        await vm.setPlayed(false, episodes: [item("a", podcastID: 1), item("b", podcastID: 2), item("c", podcastID: 1)])
        #expect(actions.attempts == 2, "one call per show, the working show included")
        #expect(messages() == ["Could not mark as unplayed"])
    }

    @Test("a failed Mark All as Played tells the listener")
    func markAllPlayedFailure() async {
        let (vm, messages) = self.makeVM(FailingPodcastActions())
        await vm.markAllPlayed(podcastID: 1)
        #expect(messages() == ["Could not mark as played"])
    }

    @Test("a download that cannot start tells the listener")
    func downloadFailure() async {
        let (vm, messages) = self.makeVM(FailingPodcastActions())
        await vm.download(podcastID: 1, guid: "a")
        #expect(messages() == ["Could not start the download"])
    }

    @Test("Download Selected tries every episode and tells the listener once")
    func bulkDownloadFailure() async {
        let actions = FailingPodcastActions()
        let (vm, messages) = self.makeVM(actions)
        await vm.download([item("a", podcastID: 1), item("b", podcastID: 2), item("c", podcastID: 1)])
        #expect(actions.attempts == 3)
        #expect(messages() == ["Could not start the download"])
    }

    @Test("an action that works tells the listener nothing")
    func successIsSilent() async {
        let actions = FailingPodcastActions()
        actions.failingShows = []
        let (vm, messages) = self.makeVM(actions)
        await vm.markPlayed(podcastID: 1, guid: "a")
        await vm.markAllPlayed(podcastID: 1)
        await vm.download(podcastID: 1, guid: "a")
        await vm.setPlayed(true, episodes: [item("a", podcastID: 1)])
        #expect(messages().isEmpty)
    }

    @Test("the library view model shows the failure as a toast")
    func failureBecomesAToast() async throws {
        let db = try await Database(location: .inMemory)
        let library = LibraryViewModel(
            database: db,
            engine: MockTransport(),
            scanner: LibraryScanner(database: db),
            podcastActions: FailingPodcastActions()
        )
        await library.podcasts.markPlayed(podcastID: 1, guid: "a")
        #expect(library.toast?.text == "Could not mark as played")
    }
}
