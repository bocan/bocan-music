import Foundation
import Persistence
import Testing
@testable import UI

// MARK: - Helpers

private func makeEpisode(duration: Double? = 100, guid: String = "ep1") -> PodcastEpisode {
    PodcastEpisode(
        podcastID: 1,
        guid: guid,
        title: "Test Episode",
        audioURL: "https://example.com/ep.mp3",
        duration: duration,
        publishedAt: 1_700_000_000,
        addedAt: 0
    )
}

private func makeItem(
    playState: EpisodePlayState? = nil,
    position: Double = 0,
    duration: Double? = 100
) -> EpisodeListItem {
    let episode = makeEpisode(duration: duration)
    let state: PodcastEpisodeState? = playState.map { ps in
        PodcastEpisodeState(
            podcastID: 1,
            guid: episode.guid,
            playPosition: position,
            playState: ps
        )
    }
    return EpisodeListItem(episode: episode, state: state)
}

// MARK: - PodcastShowViewTests

@Suite("PodcastShowView status and duration label tests")
struct PodcastShowViewTests {
    @Test("nil state maps to .unplayed")
    func statusUnplayed() {
        let item = makeItem(playState: nil)
        if case .unplayed = status(item) {} else { Issue.record("Expected .unplayed") }
    }

    @Test("inProgress with position 30 and duration 100 gives fraction 0.30")
    func statusInProgress() {
        let item = makeItem(playState: .inProgress, position: 30, duration: 100)
        guard case let .inProgress(fraction) = status(item) else {
            Issue.record("Expected .inProgress")
            return
        }
        #expect(abs(fraction - 0.30) < 0.001)
    }

    @Test("inProgress clamp low: position 0.1 / duration 100 gives fraction 0.02")
    func statusInProgressClampLow() {
        let item = makeItem(playState: .inProgress, position: 0.1, duration: 100)
        guard case let .inProgress(fraction) = status(item) else {
            Issue.record("Expected .inProgress")
            return
        }
        #expect(abs(fraction - 0.02) < 0.001)
    }

    @Test("inProgress clamp high: position 99 / duration 100 gives fraction 0.99")
    func statusInProgressClampHigh() {
        let item = makeItem(playState: .inProgress, position: 99, duration: 100)
        guard case let .inProgress(fraction) = status(item) else {
            Issue.record("Expected .inProgress")
            return
        }
        #expect(abs(fraction - 0.99) < 0.001)
    }

    @Test("inProgress with nil duration gives fraction 0.5")
    func statusInProgressNilDuration() {
        let item = makeItem(playState: .inProgress, position: 30, duration: nil)
        guard case let .inProgress(fraction) = status(item) else {
            Issue.record("Expected .inProgress")
            return
        }
        #expect(abs(fraction - 0.5) < 0.001)
    }

    @Test("played playState maps to .played")
    func statusPlayed() {
        let item = makeItem(playState: .played)
        if case .played = status(item) {} else { Issue.record("Expected .played") }
    }

    @Test("durationLabel for unplayed shows full duration")
    func durationLabelUnplayed() {
        let item = makeItem(playState: nil, duration: 3600)
        let label = durationLabel(item)
        #expect(!label.isEmpty)
        #expect(!label.contains("left"))
    }

    @Test("durationLabel for inProgress shows remaining time")
    func durationLabelInProgress() {
        let item = makeItem(playState: .inProgress, position: 3000, duration: 3600)
        let label = durationLabel(item)
        #expect(label.contains("left"))
    }

    @Test("durationLabel for played shows full duration")
    func durationLabelPlayed() {
        let item = makeItem(playState: .played, duration: 3600)
        let label = durationLabel(item)
        #expect(!label.isEmpty)
        #expect(!label.contains("left"))
    }
}
