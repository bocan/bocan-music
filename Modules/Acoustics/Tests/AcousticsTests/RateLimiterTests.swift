import Foundation
import Testing
@testable import Acoustics

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
    @Test("single request passes immediately")
    func singleRequest() async throws {
        let clock = VirtualClock()
        let limiter = RateLimiter(maxRequests: 1, per: 1.0, clock: clock)
        let start = await clock.now()
        try await limiter.wait()
        #expect(await clock.now() - start == 0)
    }

    @Test("3-req/s bucket: 4th request waits until the oldest exits the window")
    func acoustidBucket() async throws {
        let clock = VirtualClock()
        let limiter = RateLimiter(maxRequests: 3, per: 1.0, clock: clock)
        try await limiter.wait()
        try await limiter.wait()
        try await limiter.wait()
        let start = await clock.now()
        try await limiter.wait()
        let elapsed = await clock.now() - start
        // All three fired at t=0, so the 4th waits the full window for the oldest to expire.
        #expect(elapsed == 1.0)
    }

    @Test("1-req/s bucket: 2nd request delayed by 1 s")
    func mbBucket() async throws {
        let clock = VirtualClock()
        let limiter = RateLimiter(maxRequests: 1, per: 1.0, clock: clock)
        try await limiter.wait()
        let start = await clock.now()
        try await limiter.wait()
        let elapsed = await clock.now() - start
        #expect(elapsed == 1.0)
    }

    @Test("window resets: request after interval passes immediately")
    func windowReset() async throws {
        let clock = VirtualClock()
        let limiter = RateLimiter(maxRequests: 1, per: 0.1, clock: clock)
        try await limiter.wait()
        try await clock.sleep(for: 0.15) // advance past the window
        let start = await clock.now()
        try await limiter.wait()
        #expect(await clock.now() - start == 0)
    }

    // MARK: - Cancellation (issue #272)

    /// `wait()` must propagate cancellation rather than swallowing it (the sleep
    /// previously used `try?`). When the task is already cancelled, `wait()`
    /// should throw immediately even though no rate-limit delay is needed —
    /// otherwise the caller would proceed to fire its network request.
    @Test("wait() throws when the task is already cancelled")
    func throwsWhenAlreadyCancelled() async {
        let limiter = RateLimiter(maxRequests: 1, per: 1.0)
        let task = Task<Void, Error> {
            // Spin until cancellation is observed so wait() runs in a known
            // cancelled context (deterministic, not timing-dependent).
            while !Task.isCancelled {
                await Task.yield()
            }
            try await limiter.wait()
        }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    /// Cancelling while `wait()` is blocked on the rate-limit delay must throw
    /// (the sleep is now `try`, not `try?`), so a cancelled identification does
    /// not fire its request after the delay. Uses the real `SystemRateLimiterClock`
    /// so there is a live `Task.sleep` to cancel mid-flight.
    @Test("wait() throws when cancelled during the rate-limit delay")
    func throwsWhenCancelledDuringDelay() async throws {
        // Long window so the second wait() must sleep, giving us time to cancel.
        let limiter = RateLimiter(maxRequests: 1, per: 5.0)
        try await limiter.wait() // fills the bucket

        let task = Task<Void, Error> { try await limiter.wait() }
        // Let the second wait() enter its Task.sleep before cancelling.
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }
}
