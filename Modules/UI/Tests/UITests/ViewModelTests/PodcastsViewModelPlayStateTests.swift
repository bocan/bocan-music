import Foundation
import Persistence
import Testing
@testable import UI

// MARK: - Stub

/// Records the selection play-state calls so the grouping can be asserted.
private final class PlayStateRecordingActions: PodcastActions, @unchecked Sendable {
    struct Call: Equatable {
        var played: Bool
        var podcastID: Int64
        var guids: [String]
    }

    private(set) var calls: [Call] = []
    private(set) var singleCalls = 0

    func markPlayed(podcastID: Int64, guids: [String]) async {
        self.calls.append(Call(played: true, podcastID: podcastID, guids: guids))
    }

    func markUnplayed(podcastID: Int64, guids: [String]) async {
        self.calls.append(Call(played: false, podcastID: podcastID, guids: guids))
    }

    func markPlayed(podcastID: Int64, guid: String) async {
        self.singleCalls += 1
    }

    func markUnplayed(podcastID: Int64, guid: String) async {
        self.singleCalls += 1
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
        UIOPMLImportSummary()
    }

    func exportOPML() async throws -> Data {
        Data()
    }
}

// MARK: - Helpers

private func item(_ guid: String, state: EpisodePlayState?, podcastID: Int64 = 1) -> EpisodeListItem {
    let episode = PodcastEpisode(
        podcastID: podcastID,
        guid: guid,
        title: "Episode \(guid)",
        audioURL: "https://example.test/\(guid).mp3",
        addedAt: 0
    )
    let row = state.map { PodcastEpisodeState(podcastID: podcastID, guid: guid, playState: $0) }
    return EpisodeListItem(episode: episode, state: row)
}

// MARK: - PodcastsViewModelPlayStateTests

/// Mark Selected as Played / Unplayed over a multi-row selection (#635).
@Suite("PodcastsViewModel selection play state")
@MainActor
struct PodcastsViewModelPlayStateTests {
    private let mixed = [
        item("never", state: nil),
        item("unplayed", state: .unplayed),
        item("half", state: .inProgress),
        item("done", state: .played),
    ]

    @Test("Mark Selected as Played targets every episode not already played")
    func toMarkPlayed() {
        let guids = PodcastsViewModel.episodesToMarkPlayed(self.mixed).map(\.episode.guid)
        #expect(guids == ["never", "unplayed", "half"])
    }

    @Test("Mark Selected as Unplayed targets only played episodes; in-progress ones keep their place")
    func toMarkUnplayed() {
        let guids = PodcastsViewModel.episodesToMarkUnplayed(self.mixed).map(\.episode.guid)
        #expect(guids == ["done"])
    }

    @Test("setPlayed sends one batch call for a one-show selection, never per-episode calls")
    func oneBatchCall() async {
        let actions = PlayStateRecordingActions()
        let vm = PodcastsViewModel(library: nil, actions: actions)

        await vm.setPlayed(true, episodes: PodcastsViewModel.episodesToMarkPlayed(self.mixed))

        #expect(actions.calls == [.init(played: true, podcastID: 1, guids: ["never", "unplayed", "half"])])
        #expect(actions.singleCalls == 0)
    }

    @Test("setPlayed(false) routes to markUnplayed")
    func unplayedRoute() async {
        let actions = PlayStateRecordingActions()
        let vm = PodcastsViewModel(library: nil, actions: actions)

        await vm.setPlayed(false, episodes: [item("done", state: .played)])

        #expect(actions.calls == [.init(played: false, podcastID: 1, guids: ["done"])])
    }

    @Test("setPlayed groups a cross-show selection into one call per show")
    func groupsByShow() async {
        let actions = PlayStateRecordingActions()
        let vm = PodcastsViewModel(library: nil, actions: actions)

        await vm.setPlayed(true, episodes: [
            item("a1", state: nil, podcastID: 1),
            item("b1", state: nil, podcastID: 2),
            item("a2", state: .inProgress, podcastID: 1),
        ])

        #expect(actions.calls.count == 2)
        let byShow = Dictionary(uniqueKeysWithValues: actions.calls.map { ($0.podcastID, $0.guids) })
        #expect(byShow[1] == ["a1", "a2"])
        #expect(byShow[2] == ["b1"])
    }

    @Test("setPlayed with an empty selection makes no call")
    func emptySelection() async {
        let actions = PlayStateRecordingActions()
        let vm = PodcastsViewModel(library: nil, actions: actions)

        await vm.setPlayed(true, episodes: [])

        #expect(actions.calls.isEmpty)
    }
}
