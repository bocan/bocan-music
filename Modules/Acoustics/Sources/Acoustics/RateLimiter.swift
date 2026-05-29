import Foundation

// MARK: - RateLimiter

/// Sliding-window token-bucket rate limiter.
///
/// Allows at most `maxRequests` per `interval` seconds.
/// Callers `await limiter.wait()` before firing each request.
public actor RateLimiter {
    private let maxRequests: Int
    private let interval: TimeInterval
    private var timestamps: [Date] = []

    public init(maxRequests: Int, per interval: TimeInterval) {
        self.maxRequests = maxRequests
        self.interval = interval
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

        let now = Date()
        let windowStart = now.addingTimeInterval(-self.interval)
        self.timestamps.removeAll { $0 < windowStart }

        if self.timestamps.count >= self.maxRequests {
            let oldest = self.timestamps[0]
            let delay = oldest.addingTimeInterval(self.interval).timeIntervalSince(now)
            if delay > 0 {
                try await Task.sleep(for: .seconds(delay))
            }
            let newNow = Date()
            self.timestamps.removeAll { $0 < newNow.addingTimeInterval(-self.interval) }
        }

        self.timestamps.append(Date())
    }
}
