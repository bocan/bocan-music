import Foundation
import Testing
@testable import Acoustics

@Suite("RateLimiter")
struct RateLimiterTests {
    @Test("single request passes immediately")
    func singleRequest() async throws {
        let limiter = RateLimiter(maxRequests: 1, per: 1.0)
        let start = Date()
        try await limiter.wait()
        #expect(Date().timeIntervalSince(start) < 0.1)
    }

    @Test("3-req/s bucket: 4th request delayed by ≥ 333 ms")
    func acoustidBucket() async throws {
        let limiter = RateLimiter(maxRequests: 3, per: 1.0)
        try await limiter.wait()
        try await limiter.wait()
        try await limiter.wait()
        let start = Date()
        try await limiter.wait()
        let elapsed = Date().timeIntervalSince(start)
        // 1s / 3 requests ≈ 333 ms. Allow generous tolerance for CI.
        #expect(elapsed >= 0.25)
    }

    @Test("1-req/s bucket: 2nd request delayed by ≥ 1 s")
    func mbBucket() async throws {
        let limiter = RateLimiter(maxRequests: 1, per: 1.0)
        try await limiter.wait()
        let start = Date()
        try await limiter.wait()
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed >= 0.8)
    }

    @Test("window resets: request after interval passes immediately")
    func windowReset() async throws {
        let limiter = RateLimiter(maxRequests: 1, per: 0.1)
        try await limiter.wait()
        try await Task.sleep(for: .milliseconds(150))
        let start = Date()
        try await limiter.wait()
        #expect(Date().timeIntervalSince(start) < 0.1)
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
    /// not fire its request after the delay.
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
