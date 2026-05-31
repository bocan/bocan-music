import Foundation

// MARK: - RateLimiterClock

/// Time source for `RateLimiter`. Injectable so tests can drive logical time
/// instead of asserting on real wall-clock elapsed time, which is flaky under
/// CI load (#321).
public protocol RateLimiterClock: Sendable {
    /// The current time, in seconds, on an arbitrary monotonic reference.
    func now() async -> TimeInterval
    /// Suspends for `duration` seconds, honouring task cancellation.
    func sleep(for duration: TimeInterval) async throws
}

/// Production clock: wall-clock `Date` plus a cancellable `Task.sleep`.
public struct SystemRateLimiterClock: RateLimiterClock {
    public init() {}

    public func now() -> TimeInterval {
        Date().timeIntervalSinceReferenceDate
    }

    public func sleep(for duration: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(duration))
    }
}

// MARK: - RateLimiter

/// Sliding-window token-bucket rate limiter.
///
/// Allows at most `maxRequests` per `interval` seconds.
/// Callers `await limiter.wait()` before firing each request.
public actor RateLimiter {
    private let maxRequests: Int
    private let interval: TimeInterval
    private let clock: any RateLimiterClock
    /// Request times, in the injected clock's units, oldest first.
    private var timestamps: [TimeInterval] = []

    public init(
        maxRequests: Int,
        per interval: TimeInterval,
        clock: any RateLimiterClock = SystemRateLimiterClock()
    ) {
        self.maxRequests = maxRequests
        self.interval = interval
        self.clock = clock
    }

    /// Blocks until the next request can be sent within the rate budget.
    ///
    /// Throws `CancellationError` if the calling task is cancelled before or
    /// during the wait, so a cancelled identification does not fire its request
    /// after the rate-limit delay. (Previously the sleep used `try?`, swallowing
    /// cancellation and letting the caller proceed regardless.)
    public func wait() async throws {
        // Bail immediately if the task was already cancelled, even when no delay
        // is required, so we never append a timestamp / let the caller continue.
        try Task.checkCancellation()

        let now = await self.clock.now()
        let windowStart = now - self.interval
        self.timestamps.removeAll { $0 < windowStart }

        if self.timestamps.count >= self.maxRequests {
            let oldest = self.timestamps[0]
            let delay = oldest + self.interval - now
            if delay > 0 {
                try await self.clock.sleep(for: delay)
            }
            let newNow = await self.clock.now()
            self.timestamps.removeAll { $0 < newNow - self.interval }
        }

        await self.timestamps.append(self.clock.now())
    }
}
