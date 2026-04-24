import Foundation

// MARK: - RateLimiter

/// Token-bucket rate limiter.
///
/// Allows at most `maxRequests` per `interval` seconds.  Callers `await` the
/// `wait()` method before firing each request; it sleeps as long as necessary
/// to honour the rate.
public actor RateLimiter {
    private let maxRequests: Int
    private let interval: TimeInterval
    /// Timestamps (monotonic) of the most recent requests, oldest first.
    private var timestamps: [Date] = []

    /// Creates a limiter that allows `maxRequests` requests per `interval`.
    public init(maxRequests: Int, per interval: TimeInterval) {
        self.maxRequests = maxRequests
        self.interval = interval
    }

    /// Waits until it is safe to fire the next request.
    ///
    /// Returns immediately if the current request count is within the budget;
    /// otherwise sleeps until the oldest timestamp falls outside the window.
    public func wait() async {
        let now = Date()
        // Evict timestamps older than the window.
        let windowStart = now.addingTimeInterval(-self.interval)
        self.timestamps.removeAll { $0 < windowStart }

        if self.timestamps.count >= self.maxRequests {
            // Must wait until the oldest request exits the window.
            let oldest = self.timestamps[0]
            let delay = oldest.addingTimeInterval(self.interval).timeIntervalSince(now)
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            // Re-evict after sleeping.
            let newNow = Date()
            self.timestamps.removeAll { $0 < newNow.addingTimeInterval(-self.interval) }
        }

        self.timestamps.append(Date())
    }
}
