import Foundation
import Testing
@testable import Playback

// MARK: - CrossfadeDelayClampTests

/// Regression for #271: the crossfade-out delay feeds `UInt64(delay * 1e9)`,
/// which traps on overflow or NaN. `crossfadeOutDelaySeconds` must always
/// return a finite value safe for that cast.
@Suite("QueuePlayer crossfade delay clamp")
struct CrossfadeDelayClampTests {
    @Test("a normal remaining time yields remaining minus the half-duration")
    func normalDelay() {
        let delay = QueuePlayer.crossfadeOutDelaySeconds(remaining: 200, halfDuration: 5)
        #expect(delay == 195)
    }

    @Test("remaining shorter than the fade clamps to zero")
    func shortRemaining() {
        let delay = QueuePlayer.crossfadeOutDelaySeconds(remaining: 3, halfDuration: 5)
        #expect(delay == 0)
    }

    @Test("an infinite duration is clamped to the upper bound, not overflowed")
    func infiniteDuration() {
        let delay = QueuePlayer.crossfadeOutDelaySeconds(remaining: .infinity, halfDuration: 5)
        #expect(delay == QueuePlayer.maxCrossfadeOutDelaySeconds)
        // The whole point: the value is finite and safe for UInt64(delay * 1e9).
        #expect(delay.isFinite)
        #expect(delay * 1_000_000_000 < Double(UInt64.max))
    }

    @Test("a NaN duration yields zero")
    func nanDuration() {
        let delay = QueuePlayer.crossfadeOutDelaySeconds(remaining: .nan, halfDuration: 5)
        #expect(delay == 0)
    }

    @Test("a huge but finite duration is capped at the upper bound")
    func hugeFiniteDuration() {
        let delay = QueuePlayer.crossfadeOutDelaySeconds(remaining: 1e18, halfDuration: 5)
        #expect(delay == QueuePlayer.maxCrossfadeOutDelaySeconds)
        // UInt64(delay * 1e9) would have trapped on the raw 1e18 value.
        #expect(UInt64(delay * 1_000_000_000) > 0)
    }
}
