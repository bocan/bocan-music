import Foundation
import Testing
@testable import Library

// MARK: - VirtualClock

/// Deterministic clock for `RateLimiter` tests: `now()` reports logical time and
/// `sleep(for:)` advances that time instantly rather than blocking. Lets the
/// timing tests assert on exact logical elapsed time instead of flaky wall-clock
/// measurements (#321).
private actor VirtualClock: RateLimiterClock {
    private var current: TimeInterval

    init(start: TimeInterval = 0) {
        self.current = start
    }

    func now() -> TimeInterval {
        self.current
    }

    func sleep(for duration: TimeInterval) async throws {
        try Task.checkCancellation()
        self.current += duration
    }
}

@Suite("RateLimiter")
struct RateLimiterTests {
    @Test func singleRequest_immediate() async {
        let clock = VirtualClock()
        let limiter = RateLimiter(maxRequests: 1, per: 1.0, clock: clock)
        let start = await clock.now()
        await limiter.wait()
        #expect(await clock.now() - start == 0)
    }

    @Test func exceedingBudget_sleeps() async {
        let clock = VirtualClock()
        let limiter = RateLimiter(maxRequests: 2, per: 0.3, clock: clock)
        // Fire 2 requests immediately (within budget)
        await limiter.wait()
        await limiter.wait()
        // Third request must wait until the oldest exits the window.
        let start = await clock.now()
        await limiter.wait()
        let elapsed = await clock.now() - start
        // Both fired at t=0, so the 3rd waits the full window.
        #expect(elapsed == 0.3)
    }

    @Test func countsResetsAfterWindow() async {
        let clock = VirtualClock()
        let limiter = RateLimiter(maxRequests: 1, per: 0.1, clock: clock)
        await limiter.wait()

        // Advance past the window.
        try? await clock.sleep(for: 0.15)

        // Now a new request should go through immediately.
        let start = await clock.now()
        await limiter.wait()
        #expect(await clock.now() - start == 0)
    }
}
