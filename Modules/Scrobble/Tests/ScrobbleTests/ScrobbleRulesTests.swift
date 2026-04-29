import Foundation
import Testing
@testable import Scrobble

@Suite("ScrobbleRules")
struct ScrobbleRulesTests {
    @Test("track shorter than 30s is never eligible")
    func shortTrackIneligible() {
        #expect(!ScrobbleRules.isEligible(elapsed: 29, duration: 29))
        #expect(!ScrobbleRules.isEligible(elapsed: 100, duration: 25)) // even with full play
    }

    @Test("60s track is eligible at 50% (30s)")
    func halfwayThrough60sQualifies() {
        #expect(ScrobbleRules.isEligible(elapsed: 30, duration: 60))
        #expect(ScrobbleRules.isEligible(elapsed: 31, duration: 60))
    }

    @Test("60s track played 29s is not eligible")
    func almostHalfwayThrough60sFails() {
        #expect(!ScrobbleRules.isEligible(elapsed: 29, duration: 60))
    }

    @Test("10-minute track is eligible at 4 minutes regardless of fraction")
    func longTrackQualifiesAt240s() {
        #expect(ScrobbleRules.isEligible(elapsed: 240, duration: 600))
        #expect(!ScrobbleRules.isEligible(elapsed: 239, duration: 600))
    }

    @Test("zero elapsed is never eligible")
    func zeroElapsed() {
        #expect(!ScrobbleRules.isEligible(elapsed: 0, duration: 60))
    }

    @Test("backdate window: in-range / out-of-range")
    func backdateWindow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(ScrobbleRules.isWithinBackdateWindow(now, now: now))
        #expect(ScrobbleRules.isWithinBackdateWindow(now.addingTimeInterval(-13 * 86400), now: now))
        #expect(!ScrobbleRules.isWithinBackdateWindow(now.addingTimeInterval(-15 * 86400), now: now))
        #expect(ScrobbleRules.isWithinBackdateWindow(now.addingTimeInterval(3600), now: now))
        #expect(!ScrobbleRules.isWithinBackdateWindow(now.addingTimeInterval(2 * 86400), now: now))
    }
}

@Suite("PlayAccumulator")
struct PlayAccumulatorTests {
    @Test("paused time does not count")
    func pausedTimeExcluded() {
        var acc = PlayAccumulator()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        acc.reset(at: t0)
        acc.tick(at: t0.addingTimeInterval(10))
        acc.pause(at: t0.addingTimeInterval(10))
        acc.tick(at: t0.addingTimeInterval(40)) // 30s of paused time → ignored
        acc.resume(at: t0.addingTimeInterval(40))
        acc.tick(at: t0.addingTimeInterval(70)) // +30s playing
        #expect(abs(acc.elapsed - 40) < 0.01)
    }

    @Test("reset wipes counters")
    func resetClearsState() {
        var acc = PlayAccumulator()
        let t0 = Date()
        acc.reset(at: t0)
        acc.tick(at: t0.addingTimeInterval(50))
        #expect(acc.elapsed > 0)
        acc.reset(at: t0.addingTimeInterval(60))
        #expect(acc.elapsed == 0)
        #expect(acc.isPlaying)
    }
}
