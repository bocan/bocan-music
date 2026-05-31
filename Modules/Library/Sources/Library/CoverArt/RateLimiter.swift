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

/// Production clock: wall-clock `Date` plus `Task.sleep`.
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

/// Token-bucket rate limiter.
///
/// Allows at most `maxRequests` per `interval` seconds.  Callers `await` the
/// `wait()` method before firing each request; it sleeps as long as necessary
/// to honour the rate.
public actor RateLimiter {
    private let maxRequests: Int
    private let interval: TimeInterval
    private let clock: any RateLimiterClock
    /// Times of the most recent requests, in the injected clock's units, oldest first.
    private var timestamps: [TimeInterval] = []

    /// Creates a limiter that allows `maxRequests` requests per `interval`.
    public init(
        maxRequests: Int,
        per interval: TimeInterval,
        clock: any RateLimiterClock = SystemRateLimiterClock()
    ) {
        self.maxRequests = maxRequests
        self.interval = interval
        self.clock = clock
    }

    /// Waits until it is safe to fire the next request.
    ///
    /// Returns immediately if the current request count is within the budget;
    /// otherwise sleeps until the oldest timestamp falls outside the window.
    public func wait() async {
        let now = await self.clock.now()
        // Evict timestamps older than the window.
        let windowStart = now - self.interval
        self.timestamps.removeAll { $0 < windowStart }

        if self.timestamps.count >= self.maxRequests {
            // Must wait until the oldest request exits the window.
            let oldest = self.timestamps[0]
            let delay = oldest + self.interval - now
            if delay > 0 {
                try? await self.clock.sleep(for: delay)
            }
            // Re-evict after sleeping.
            let newNow = await self.clock.now()
            self.timestamps.removeAll { $0 < newNow - self.interval }
        }

        await self.timestamps.append(self.clock.now())
    }
}
