import Foundation

// MARK: - RetryPolicy

/// Exponential backoff with jitter and a hard cap.
///
/// Used by `ScrobbleQueueWorker` for transient failures (HTTP 5xx,
/// network errors, Last.fm error code 16). After `maxAttempts` the row is
/// marked `dead` and surfaced in the dead-letter UI.
public struct RetryPolicy: Sendable, Equatable {
    /// Initial delay applied to attempt #1's failure (i.e. the wait before attempt #2).
    public let baseDelay: TimeInterval
    /// Hard upper bound on a single delay.
    public let maxDelay: TimeInterval
    /// Stop retrying after this many cumulative attempts.
    public let maxAttempts: Int
    /// Multiplicative jitter range. `1.0 ± jitter` — e.g. 0.2 means [0.8x, 1.2x].
    public let jitter: Double

    public init(
        baseDelay: TimeInterval = 30,
        maxDelay: TimeInterval = 60 * 60, // 1 hour
        maxAttempts: Int = 20,
        jitter: Double = 0.2
    ) {
        precondition(baseDelay > 0)
        precondition(maxDelay >= baseDelay)
        precondition(maxAttempts > 0)
        precondition(jitter >= 0 && jitter < 1)
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.maxAttempts = maxAttempts
        self.jitter = jitter
    }

    /// The default policy used in production.
    public static let `default` = RetryPolicy()

    /// Returns the delay (in seconds) to wait *before* the given attempt number.
    /// `attemptNumber` is 1-indexed (the 1st attempt has delay 0).
    public func delay(forAttempt attemptNumber: Int, randomSource: () -> Double = { Double.random(in: 0 ... 1) }) -> TimeInterval {
        if attemptNumber <= 1 { return 0 }
        let exponent = Double(attemptNumber - 1)
        let raw = self.baseDelay * pow(2.0, exponent - 1)
        let capped = min(raw, self.maxDelay)
        let r = randomSource()
        let factor = (1.0 - self.jitter) + (2.0 * self.jitter * r)
        return capped * factor
    }

    /// `true` once the row has used up its retries and should be marked dead.
    public func isExhausted(attempts: Int) -> Bool {
        attempts >= self.maxAttempts
    }
}
