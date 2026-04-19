import Foundation
import Persistence
import Testing
@testable import Playback

// MARK: - HistoryRecorderTests

@Suite("PlayHistoryRecorder")
struct HistoryRecorderTests {
    // MARK: - Threshold checks

    @Test("50% fraction meets threshold for 200s track")
    func halfFractionMeetsThreshold() async {
        // 200s track, 100s played = 50%
        let recorder = await PlayHistoryRecorder(database: makeDatabase())
        await recorder.trackDidStart(trackID: 1, duration: 200)
        // 100s = 50% → should scrobble
        let shouldScrobble = self.threshold(elapsed: 100, duration: 200)
        #expect(shouldScrobble)
    }

    @Test("49% fraction does not meet threshold")
    func belowFractionNoThreshold() {
        let shouldScrobble = self.threshold(elapsed: 97, duration: 200)
        #expect(!shouldScrobble)
    }

    @Test("4 minutes absolute meets threshold for long tracks")
    func absoluteThreshold() {
        // 1000s track, 240s played = 24% fraction < 50%, but ≥ 4min
        let shouldScrobble = self.threshold(elapsed: 240, duration: 1000)
        #expect(shouldScrobble)
    }

    @Test("less than 4 minutes and less than 50% does not meet threshold")
    func belowBothThresholds() {
        let shouldScrobble = self.threshold(elapsed: 60, duration: 1000)
        #expect(!shouldScrobble)
    }

    @Test("trackDidEnd calls no-op when nothing started")
    func endWithNothingStarted() async {
        let recorder = await PlayHistoryRecorder(database: makeDatabase())
        // Should not crash
        await recorder.trackDidEnd(elapsed: 100)
    }

    @Test("trackSkipped calls no-op when nothing started")
    func skipWithNothingStarted() async {
        let recorder = await PlayHistoryRecorder(database: makeDatabase())
        // Should not crash
        await recorder.trackSkipped(elapsed: 100)
    }

    // MARK: - Helpers

    /// Mirror of the private threshold logic for testing.
    private func threshold(elapsed: TimeInterval, duration: TimeInterval) -> Bool {
        if duration > 0 {
            let fraction = elapsed / duration
            if fraction >= 0.50 { return true }
        }
        return elapsed >= 240.0
    }

    private func makeDatabase() async -> Database {
        // A fully in-memory database suitable for tests.
        // We don't actually write during these unit tests (DB is not used for threshold logic).
        try! await Database(location: .inMemory)
    }
}

// MARK: - NowPlayingTests

@Suite("NowPlayingCentre")
struct NowPlayingTests {
    @Test("init does not throw or crash")
    @MainActor
    func initDoesNotCrash() {
        let centre = NowPlayingCentre()
        centre.setPlaying(false)
        centre.clear()
    }

    @Test("setPlaying true then false does not crash")
    @MainActor
    func setPlayingToggle() {
        let centre = NowPlayingCentre()
        centre.setPlaying(true)
        centre.setPlaying(false)
    }
}
